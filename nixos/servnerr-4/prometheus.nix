{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:

let
  inherit (config.networking) hostName;
  inherit (config.services.prometheus) exporters;

  # URL of a service on this machine, by port.
  self = port: "http://${qualify hostName}:${toString port}";
  prometheusUrl = self config.services.prometheus.port;
  alertmanagerUrl = self config.services.prometheus.alertmanager.port;
  grafanaUrl = self config.services.grafana.settings.server.http_port;
  lokiUrl = self config.services.loki.configuration.server.http_listen_port;

  # Extracts the port from a "host:port" or ":port" listen address.
  portOf = addr: lib.toInt (lib.last (lib.splitString ":" addr));

  # Finds the port of Alloy's HTTP server from its listen address flag; see
  # nixos/modules/alloy.nix.
  alloyPort =
    cfg:
    portOf (
      lib.head (lib.filter (lib.hasPrefix "--server.http.listen-addr=") cfg.services.alloy.extraFlags)
    );

  # Finds the port of the CoreDNS prometheus plugin in a Corefile.
  corednsPort =
    corefile:
    let
      matches = lib.filter (m: m != null) (
        map (line: builtins.match ".*prometheus :([0-9]+).*" line) (lib.splitString "\n" corefile)
      );
    in
    lib.toInt (lib.head (lib.head matches));

  # Exporters to skip: probers scraped through by other jobs, and renamed
  # options which only emit a warning when read.
  ignoredExporters = [
    "snmp"
    "unifi-poller"
  ];

  # Scrape jobs discovered from a NixOS configuration: each enabled Prometheus
  # exporter, plus the metrics endpoints of services which expose their own.
  # Hosts which set homelab.sshProbe get an SSH banner probe, and hosts
  # sending router advertisements are routers for alerting purposes.
  discover =
    cfg:
    let
      # Removed exporters throw when read, so probe them with tryEval.
      enabled =
        name: e:
        let
          r = builtins.tryEval (e.enable or false);
        in
        !(lib.elem name ignoredExporters) && r.success && r.value;
    in
    {
      jobs =
        lib.mapAttrs (_: e: { inherit (e) port; }) (
          lib.filterAttrs enabled cfg.services.prometheus.exporters
        )
        // lib.optionalAttrs cfg.services.prometheus.alertmanager.enable {
          alertmanager.port = cfg.services.prometheus.alertmanager.port;
        }
        // lib.optionalAttrs cfg.services.alloy.enable {
          alloy.port = alloyPort cfg;
        }
        // lib.optionalAttrs cfg.services.coredns.enable {
          coredns.port = corednsPort cfg.services.coredns.config;
        }
        // lib.optionalAttrs cfg.services.corerad.enable {
          corerad.port = portOf cfg.services.corerad.settings.debug.address;
        }
        // lib.optionalAttrs cfg.services.grafana.enable {
          grafana.port = cfg.services.grafana.settings.server.http_port;
        }
        // lib.optionalAttrs cfg.services.loki.enable {
          loki.port = cfg.services.loki.configuration.server.http_listen_port;
        }
        // lib.optionalAttrs cfg.services.prometheus.enable {
          prometheus.port = cfg.services.prometheus.port;
        }
        // lib.optionalAttrs cfg.services.zrepl.enable {
          zrepl.port = portOf (lib.head cfg.services.zrepl.settings.global.monitoring).listen;
        }
        # dn42_peer_exporter runs on every host terminating external dn42
        # tunnels, probing each peer's link-local address across its own
        # tunnel; see the router host's dn42.nix and the DN42PeerLatencyHigh
        # alert. The option exists only on hosts that import that file, and
        # holds the external peers alone: the internal dn42i-* VLANs are
        # declared separately and are not tunnels.
        // lib.optionalAttrs (cfg.homelab.dn42.peers or { } != { }) {
          dn42_peer.port = 9631;
        }
        # frr_exporter, for the IGP on the site interconnects. Hand-added for
        # the same reason as dn42_peer: there is no
        # services.prometheus.exporters.frr module for discover to find, so
        # the option which turns the IGP on is what names the job.
        // lib.optionalAttrs (cfg.homelab.interconnect.isis.enable or false) {
          frr.port = 9342;
        };
      ssh = cfg.homelab.sshProbe or false;
      router = cfg.services.corerad.enable;
    };

  # Every NixOS machine in this flake, by host name.
  nixosHosts = lib.mapAttrs (_: system: discover system.config) inputs.self.nixosConfigurations;

  # Containers and microvm guests on those machines which have a dev0
  # inventory entry, by their DNS name. Other containers share their host's
  # network and need nothing.
  inherit (config.homelab.inventory)
    domain
    roles
    sites
    tailnetDomain
    ;

  # Each machine's site domain, from its own configuration, so a target at
  # another site is named there rather than here.
  machineDomains = lib.mapAttrs (
    _: system: sites.${system.config.homelab.site}.domain
  ) inputs.self.nixosConfigurations;

  # An inventory host is published under its segment's namespace, not its
  # bare name; see nixos/inventory/. A machine at a site with no LAN is not a
  # host on a segment at all, and is published at its loopback instead, so
  # both registries are consulted. Loopbacks are plain data for exactly this:
  # a host entry elsewhere would be a placeholder this machine cannot read.
  dnsNames =
    lib.mapAttrs (_: h: h.dnsName) config.homelab.inventory.hosts
    // lib.concatMapAttrs (
      _: site:
      lib.mapAttrs (_: lo: lo.dnsName) (lib.filterAttrs (_: lo: lo.dnsName != null) site.loopbacks)
    ) sites;

  # Fully qualify a scrape target's host, so resolution never depends on the
  # resolver's search list being present — which on most segments is not
  # there at all. Only a name already ending in its domain (the dev
  # containers, keyed by DNS name) is left alone: a dot elsewhere, as in
  # "ipv4.<host>", does not make a name absolute.
  qualify =
    name:
    let
      d = machineDomains.${name} or domain;
    in
    if lib.hasSuffix ".${d}" name then name else "${dnsNames.${name} or name}.${d}";
  containerHosts = lib.listToAttrs (
    lib.concatMap (
      system:
      let
        guests =
          lib.mapAttrs (_: c: c.config) system.config.containers
          // lib.mapAttrs (_: vm: vm.config.config) (system.config.microvm.vms or { });
      in
      lib.concatMap (
        name:
        lib.optional (config.homelab.inventory.hosts ? ${name}) (
          lib.nameValuePair (qualify name) (discover guests.${name})
        )
      ) (lib.attrNames guests)
    ) (lib.attrValues inputs.self.nixosConfigurations)
  );

  # Machines not managed by this flake (alerts = false for PCs which are often
  # off), plus jobs which discover cannot find on managed machines.
  otherHosts = {
    hass = {
      jobs = {
        alloy.port = 12345;
        node.port = 9100;
      };
    };
    nerr-4 = {
      jobs = {
        node.port = 9100;
      };
      alerts = false;
    };
  }
  # consrv exposes its own metrics endpoint on every monitor role holder; see
  # the monitor host's consrv.nix.
  // lib.genAttrs roles.monitor (_: {
    jobs.consrv.port = 9288;
  })
  # nftables_exporter runs on every IGP node, the router, edge and server
  # role holders; see nixos/modules/nftables-exporter.nix. The exporter
  # mirrors nftables faithfully, so the homelab naming conventions are
  # split into labels here: accounting counters named <lan>_wan_<dir> gain
  # device and direction, and per-host set elements keyed "<ifname> . <addr>"
  # gain device and address. An edge has neither and its counters pass
  # through.
  // lib.genAttrs (roles.router ++ roles.edge ++ roles.server) (_: {
    jobs.nftables = {
      port = 9630;
      metric_relabel_configs =
        let
          split =
            source: regex: fields:
            {
              source_labels = [ source ];
              inherit regex;
            }
            // fields;
        in
        [
          (split "name" "(.+)_wan_(in|out)" {
            target_label = "device";
            replacement = "$1";
          })
          (split "name" "(.+)_wan_(in|out)" {
            target_label = "direction";
            replacement = "$2";
          })
          (split "element" "(.+) \\. (.+)" {
            target_label = "device";
            replacement = "$1";
          })
          (split "element" "(.+) \\. (.+)" {
            target_label = "address";
            replacement = "$2";
          })
          # The circuit accounting sets (see modules/interconnect.nix):
          # icl_<direction>_v<family>, keyed by the circuit's interface.
          # afi as the FRR exporter labels an address family, since family
          # here is already nftables' table family.
          (split "set" "icl_(in|out)_v([46])" {
            target_label = "direction";
            replacement = "$1";
          })
          (split "set" "icl_(in|out)_v([46])" {
            target_label = "afi";
            replacement = "ipv$2";
          })
          (split "element" "(icl-.+)" {
            target_label = "device";
            replacement = "$1";
          })
        ];
    };
  });

  hosts = lib.recursiveUpdate (nixosHosts // containerHosts) otherHosts;

  # Blackbox HTTP probe targets: local service health endpoints, plus the
  # Tailscale Services TLS frontends, which also validates their
  # certificates; see the TLSCertificateExpiringSoon alert. A new TLS
  # frontend is a prompt to add its probe, since nothing else would notice
  # its certificate expiring.
  #
  # Certificates a machine in this flake issues through the acme module are
  # discovered from its configuration instead, so the probe arrives with the
  # certificate and never before it.
  probes =
    map (at hostName) [
      "${alertmanagerUrl}/-/healthy"
      "${grafanaUrl}/api/health"
      "${lokiUrl}/ready"
      "${prometheusUrl}/-/healthy"

      "https://alertmanager.${tailnetDomain}/-/healthy"
      "https://grafana.${tailnetDomain}/api/health"
      "https://loki.${tailnetDomain}/ready"
      "https://prometheus.${tailnetDomain}/-/healthy"
    ]
    # A certificate belongs to the machine that issues it, so its probe
    # carries that machine's site rather than this one's.
    ++ lib.concatMap (
      name:
      map (cert: at name "https://${cert.domain}/") (
        lib.attrValues inputs.self.nixosConfigurations.${name}.config.security.acme.certs
      )
    ) (lib.attrNames inputs.self.nixosConfigurations);

  # Blackbox ICMP probe targets: public anchors over both IPv4 and IPv6, so
  # internet reachability, latency, and loss are tracked per address family.
  # Two providers, so loss on one path can be told apart from loss on the
  # WAN itself. Probes follow the router's default routing policy, so they
  # observe the active WAN path only; a failed standby WAN is not visible
  # here.
  pings =
    map nowhere [
      "1.1.1.1"
      "2606:4700:4700::1111"
      "8.8.8.8"
      "2001:4860:4860::8888"
    ]
    # Liveness for the cloud-managed switches and APs in the management LAN
    # inventory, which expose no SNMP or local API; ping is the only local
    # signal that they are alive.
    #
    # Fully qualified, as are the SNMP targets below: a relative name with a
    # dot in it is tried as absolute first, so "ipv4.<host>" cost an NXDOMAIN
    # on every probe before the search domain rescued it, and made every probe
    # depend on the resolver's search list. Hosts the inventory gives no IPv6
    # address have only an A record, so their bare name is enough; the rest
    # are pinned to IPv4 by name, which also keeps the family label below
    # truthful for them.
    ++ map (h: at h.name (qualify (if h.ula == null then h.dnsName else "ipv4.${h.dnsName}"))) (
      lib.filter (
        h: lib.hasPrefix "switch-" h.name || lib.hasPrefix "ap-" h.name
      ) config.homelab.inventory.interfaces.mgmt0.hosts
    );

  # Blackbox DNS probe targets: CoreDNS on every router role holder,
  # exercising resolution of a known internal name end to end rather than
  # just process liveness.
  dnsServers = map (name: at name "${qualify name}:53") roles.router;

  # SNMP targets queried via the cyberpower module. The devices are not
  # reliable enough to alert on.
  snmpCyberpowerJob = "snmp-cyberpower";
  snmpCyberpower = map (h: at h (qualify h)) [
    "pdu01"
    "ups01"
  ];

  # NixOS exporters running on this machine which probe jobs are relabeled
  # through.
  local = exporter: "${qualify hostName}:${toString exporters.${exporter}.port}";

  # Hosts in the inventory matching a predicate, by name.
  hostsWhere = pred: lib.attrNames (lib.filterAttrs (_: pred) hosts);

  # One static scrape job per distinct job name, targeting every host which
  # runs it. Job settings beyond the port come from the first host defining
  # them.
  jobNames = lib.unique (lib.concatMap (h: lib.attrNames h.jobs) (lib.attrValues hosts));
  exporterJobs = lib.genAttrs jobNames (
    job:
    let
      running = lib.filterAttrs (_: h: h.jobs ? ${job}) hosts;
      settings = lib.head (lib.attrValues running);
    in
    {
      job_name = job;
      static_configs = siteConfigs (
        lib.mapAttrsToList (host: h: at host "${qualify host}:${toString h.jobs.${job}.port}") running
      );
    }
    // lib.optionalAttrs (settings.jobs.${job} ? metrics_path) {
      inherit (settings.jobs.${job}) metrics_path;
    }
    // lib.optionalAttrs (settings.jobs.${job} ? metric_relabel_configs) {
      inherit (settings.jobs.${job}) metric_relabel_configs;
    }
  );

  # Hosts with SSH banner probing enabled: the machines a bad firewall rule
  # would lock the admin out of, not every host running sshd. It costs a
  # journal line a minute, which on a dev guest buried the real logins.
  sshTargets = map (host: at host "${qualify host}:22") (hostsWhere (h: h.ssh or false));

  # Host lists are qualified to match the instance labels the targets above
  # produce; the rules only ever evaluate current data, so nothing needs to
  # match the bare names series carried before targets were qualified.
  # Anycast service addresses and the site expected to answer each, from
  # every machine's own declaration (see nixos/modules/anycast.nix). A site
  # answers while any one of its nodes holds the address, so the pair is what
  # an alert watches rather than the machine; a second node at a site adds no
  # entry. The address comes from the same option the node configures, so an
  # alert can never name one the fabric does not.
  anycastServices = lib.unique (
    lib.concatMap (
      system:
      lib.concatLists (
        lib.mapAttrsToList (
          service: cfg:
          let
            site = system.config.homelab.site;
          in
          [
            {
              inherit service site;
              address = cfg.address6;
            }
          ]
          ++ lib.optional (cfg.address4 != null) {
            inherit service site;
            address = cfg.address4;
          }
        ) (system.config.homelab.anycast.services or { })
      )
    ) (lib.attrValues inputs.self.nixosConfigurations)
  );

  # Routers running the IGP, which is how many LSPs each level-2 database
  # should hold. Counted from the machines that enable it rather than from
  # the inventory's system IDs, because an ID is assigned while a site is
  # being scaffolded and before any machine carries it. It is the level-2
  # router count while modules/interconnect.nix renders level-2-only
  # circuits; a machine speaking only level 1 would need excluding.
  isisRouterCount = lib.count (system: system.config.homelab.interconnect.isis.enable or false) (
    lib.attrValues inputs.self.nixosConfigurations
  );

  alerts = import ./prometheus-alerts.nix {
    inherit lib anycastServices isisRouterCount;
    exploreURL = import ./explore-url.nix { inherit lib tailnetDomain; };
    excludedHosts = map qualify (hostsWhere (h: !(h.alerts or true)));
    excludedJobs = [ snmpCyberpowerJob ];
    routers = map qualify (hostsWhere (h: h.router or false));
    # Every host expected to ship logs to Loki: the machines themselves plus
    # their containers and microvms, whose journals the hosting machine
    # ships; see nixos/modules/alloy.nix.
    logHosts =
      lib.attrNames nixosHosts
      ++ lib.concatMap (
        system: lib.attrNames system.config.containers ++ lib.attrNames (system.config.microvm.vms or { })
      ) (lib.attrValues inputs.self.nixosConfigurations);
  };

  # Discord notification body, rendered inside an embed so markdown links
  # work. One entry per alert: summary, optional description, when it started
  # (Discord renders <t:..:R> as a relative time), and links to silence it in
  # Alertmanager (all of the alert's labels pre-filled), to its source query in
  # Prometheus, to the matching log lines in Grafana if the rule provides a
  # logs_url annotation (see loki.nix), and to a runbook if it has one.
  alertmanagerTemplates = pkgs.writeText "homelab.tmpl" ''
    {{ define "homelab.discord.alert" -}}
    **{{ .Labels.alertname }}**{{ with .Labels.instance }} on `{{ . }}`{{ end }}{{ with .Annotations.summary }}: {{ . }}{{ end }}
    {{- with .Annotations.description }}
    {{ . }}{{ end }}
    {{- end }}

    {{ define "homelab.discord.message" }}
    {{- range .Alerts.Firing }}
    :fire: {{ template "homelab.discord.alert" . }}
    Since <t:{{ .StartsAt.Unix }}:R> · [Silence]({{ $.ExternalURL }}/#/silences/new?filter=%7B{{ range $i, $l := .Labels.SortedPairs }}{{ if $i }}%2C%20{{ end }}{{ $l.Name }}%3D%22{{ $l.Value | urlquery }}%22{{ end }}%7D) · [Source]({{ .GeneratorURL }}){{ with .Annotations.logs_url }} · [Logs]({{ . }}){{ end }}{{ with .Annotations.runbook_url }} · [Runbook]({{ . }}){{ end }}
    {{ end -}}
    {{- range .Alerts.Resolved }}
    :white_check_mark: {{ template "homelab.discord.alert" . }}
    Resolved <t:{{ .EndsAt.Unix }}:R> after {{ (.EndsAt.Sub .StartsAt).Seconds | humanizeDuration }}
    {{ end -}}
    {{ end }}
  '';

  # Which site a machine is at, from its own configuration, so a target
  # carries the site rather than the site being read back out of its name.
  # Anything that is not a NixOS machine of ours -- the switches, the UPS
  # cards, Home Assistant -- is at this one.
  machineSites = lib.mapAttrs (_: system: system.config.homelab.site) inputs.self.nixosConfigurations;
  siteOf = name: machineSites.${name} or config.homelab.site;

  # One static_configs entry per site, each labelled with it. Takes
  # { site, target } pairs rather than bare targets: a probe target is often
  # a URL, from which the machine it belongs to cannot be recovered
  # afterwards, so the site travels with it from where it is built. A null
  # site groups into one unlabelled entry, which is what the public ICMP
  # anchors are -- they belong to no site of ours.
  siteConfigs =
    entries:
    lib.mapAttrsToList (
      site: es:
      {
        targets = map (e: e.target) es;
      }
      // lib.optionalAttrs (site != "") { labels = { inherit site; }; }
    ) (lib.groupBy (e: if e.site == null then "" else e.site) entries);

  # A target belonging to a machine, which knows where it is.
  at = host: target: {
    site = siteOf host;
    inherit target;
  };

  # A target belonging to nowhere in particular.
  nowhere = target: {
    site = null;
    inherit target;
  };

  # Scrape a list of static targets for a job; entries carry their site.
  staticScrape = job_name: entries: {
    inherit job_name;
    static_configs = siteConfigs entries;
  };

  # Scrape targets through a blackbox exporter module at an interval.
  blackboxScrape = module: interval: entries: {
    job_name = "blackbox_${module}";
    scrape_interval = interval;
    metrics_path = "/probe";
    params.module = [ module ];
    relabel_configs = relabelTarget (local "blackbox");
    static_configs = siteConfigs entries;
  };

  # Produces a relabeling configuration that replaces the instance label with
  # the HTTP target parameter.
  relabelTarget = target: [
    {
      source_labels = [ "__address__" ];
      target_label = "__param_target";
    }
    {
      source_labels = [ "__param_target" ];
      target_label = "instance";
    }
    {
      target_label = "__address__";
      replacement = target;
    }
  ];
in
{
  # Stable tailnet names for the monitoring web UIs, e.g.
  # https://grafana.<tailnet>.ts.net; see nixos/modules/tailscale-serve.nix.
  # Port 443 terminates TLS with an automatically provisioned certificate for
  # the service name and forwards plaintext to the local backend; port 80
  # stays as a plain HTTP convenience.
  homelab.tailscale.services =
    let
      web = port: {
        "tcp:80" = "http://127.0.0.1:${toString port}";
        "tcp:443" = "tls-terminated-tcp://127.0.0.1:${toString port}";
      };
    in
    {
      alertmanager = web config.services.prometheus.alertmanager.port;
      grafana = web config.services.grafana.settings.server.http_port;
      loki = web config.services.loki.configuration.server.http_listen_port;
      prometheus = web config.services.prometheus.port;
    };

  # Secrets consumed by prometheus and alertmanager. Alerts post to the
  # Discord alerts channel via a webhook of its own, separate from the one in
  # modules/common.nix that update notifications post to; ZED shares it, see
  # storage.nix. Both webhooks live in the shared secrets file beside each
  # other, not in this machine's.
  sops.secrets = {
    "discord/alerts_webhook_url" = {
      sopsFile = ../secrets/common.yaml;
      restartUnits = [ "alertmanager.service" ];
    };
    "alertmanager/deadman_url".restartUnits = [ "alertmanager.service" ];
    "prometheus/homeassistant_token" = {
      owner = "prometheus";
      restartUnits = [ "prometheus.service" ];
    };
  };

  # alertmanager runs with DynamicUser, so hand it the Discord webhook URL via
  # systemd credentials rather than a file owned by a static user.
  systemd.services.alertmanager.serviceConfig.LoadCredential = [
    "discord_webhook_url:${config.sops.secrets."discord/alerts_webhook_url".path}"
    "deadman_url:${config.sops.secrets."alertmanager/deadman_url".path}"
  ];

  # Prometheus monitoring server and exporter configuration.
  services.prometheus = {
    enable = true;
    # Advertise the Tailscale Services TLS frontend, so links in alerts and
    # the web UI resolve anywhere on the tailnet.
    webExternalUrl = "https://prometheus.${tailnetDomain}/";

    # Credential files are not visible to promtool in the build sandbox.
    checkConfig = "syntax-only";

    # A year of history; disk is plentiful.
    retentionTime = "365d";

    # Accept recording rules remote-written by Loki's ruler; see loki.nix.
    extraFlags = [ "--web.enable-remote-write-receiver" ];

    globalConfig.scrape_interval = "15s";

    alertmanager = {
      enable = true;
      # As above: silence links in Discord notifications use this URL.
      webExternalUrl = "https://alertmanager.${tailnetDomain}/";

      # Single node: don't listen for cluster gossip.
      extraFlags = [ "--cluster.listen-address=" ];

      configuration = {
        templates = [ (toString alertmanagerTemplates) ];

        route = {
          group_by = [ "alertname" ];
          group_wait = "10s";
          group_interval = "10s";
          repeat_interval = "1h";
          receiver = "default";
          routes = [
            # Dead man's switch: keep pinging the heartbeat service while the
            # PrometheusWatchdog alert fires; it pages when the pings stop.
            {
              matchers = [ "alertname = PrometheusWatchdog" ];
              receiver = "deadman";
              group_wait = "0s";
              group_interval = "1m";
              repeat_interval = "2m";
            }
          ];
        };
        receivers = [
          {
            name = "default";
            discord_configs = [
              {
                webhook_url_file = "/run/credentials/alertmanager.service/discord_webhook_url";
                message = ''{{ template "homelab.discord.message" . }}'';
              }
            ];
          }
          {
            name = "deadman";
            webhook_configs = [
              {
                url_file = "/run/credentials/alertmanager.service/deadman_url";
                send_resolved = false;
              }
            ];
          }
        ];
      };
    };

    # Use the alertmanager running on this machine.
    alertmanagers = [
      {
        static_configs = [
          { targets = [ "${qualify hostName}:${toString config.services.prometheus.alertmanager.port}" ]; }
        ];
      }
    ];

    exporters = {
      # Node exporter already enabled on all machines.

      apcupsd.enable = true;

      blackbox = {
        enable = true;
        configFile = pkgs.writeText "blackbox.yml" (
          builtins.toJSON {
            modules = {
              http_2xx.prober = "http";
              # The NixOS module grants CAP_NET_RAW for ICMP probes.
              icmp.prober = "icmp";
              dns_lan = {
                prober = "dns";
                dns = {
                  # Through qualify, so the probe asks for the name the
                  # router actually publishes rather than assembling one,
                  # and by role so a hardware swap moves it.
                  query_name = qualify (lib.head roles.server);
                  query_type = "A";
                };
              };
              ssh_banner = {
                prober = "tcp";
                tcp.query_response = [ { expect = "^SSH-2.0-"; } ];
              };
            };
          }
        );
      };

      # SNMP exporter with the data file from release 0.30.1, matching the
      # packaged exporter; the sha256 pins the content regardless of the tag.
      snmp = {
        enable = true;
        configurationPath = builtins.fetchurl {
          url = "https://raw.githubusercontent.com/prometheus/snmp_exporter/v0.30.1/snmp.yml";
          sha256 = "1m12khms588cch43wmglz2fsxh9i15am3imvqa4i8k7lhw5yn0sf";
        };
      };
    };

    scrapeConfigs = lib.attrValues exporterJobs ++ [
      # Home Assistant requires a more custom configuration.
      {
        job_name = "homeassistant";
        metrics_path = "/api/prometheus";
        authorization.credentials_file = config.sops.secrets."prometheus/homeassistant_token".path;
        static_configs = siteConfigs [ (at "hass" "${qualify "hass"}:8123") ];
      }

      # Blackbox probes for HTTP endpoints, internet reachability per address
      # family, and end to end DNS resolution through the router.
      (blackboxScrape "http_2xx" "15s" probes)
      # ICMP targets also carry a family label so alerts distinguish the IPv4
      # and IPv6 WAN paths; IPv6 literals are the only ICMP targets with
      # colons. The family rules run first, while __address__ still holds the
      # probe target rather than the blackbox exporter.
      (
        (blackboxScrape "icmp" "15s" pings)
        // {
          relabel_configs = [
            {
              source_labels = [ "__address__" ];
              regex = ".*:.*";
              target_label = "family";
              replacement = "ipv6";
            }
            {
              source_labels = [ "__address__" ];
              regex = "[^:]*";
              target_label = "family";
              replacement = "ipv4";
            }
          ]
          ++ relabelTarget (local "blackbox");
        }
      )
      (blackboxScrape "dns_lan" "1m" dnsServers)
      # The SSH banner check produces a fair amount of log spam, so only scrape
      # it once a minute.
      (blackboxScrape "ssh_banner" "1m" sshTargets)

      # SNMP relabeling configuration required to properly replace the instance
      # names and query the correct devices.
      (lib.mkMerge [
        (staticScrape snmpCyberpowerJob snmpCyberpower)
        {
          metrics_path = "/snmp";
          params.module = [ "cyberpower" ];
          # The CyberPower cards speak SNMPv1 only; without this the exporter
          # defaults to public_v2 and every walk times out.
          params.auth = [ "public_v1" ];
          relabel_configs = relabelTarget (local "snmp");
        }
      ])
    ];

    rules = [ (builtins.toJSON alerts) ];
  };
}
