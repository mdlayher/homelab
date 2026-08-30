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

  # Services on this machine are reached directly over the LAN or Tailscale by
  # hostname; nothing is exposed via a public reverse proxy.
  self = port: "http://${hostName}:${toString port}";
  prometheusUrl = self config.services.prometheus.port;
  alertmanagerUrl = self config.services.prometheus.alertmanager.port;
  grafanaUrl = self config.services.grafana.settings.server.http_port;
  plexUrl = self 32400;

  # Extracts the port from a "host:port" or ":port" listen address.
  portOf = addr: lib.toInt (lib.last (lib.splitString ":" addr));

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

  # Scrape jobs discovered from every NixOS machine in this flake: each enabled
  # Prometheus exporter, plus the metrics endpoints of services which expose
  # their own. Hosts running sshd get an SSH banner probe, and hosts sending
  # router advertisements are routers for alerting purposes.
  nixosHosts = lib.mapAttrs (
    _: system:
    let
      cfg = system.config;

      # Removed exporters throw when read, so probe them with tryEval.
      enabled =
        name: e:
        let
          r = builtins.tryEval (e.enable or false);
        in
        r.success && r.value && !(lib.elem name ignoredExporters);
    in
    {
      jobs =
        lib.mapAttrs (_: e: { inherit (e) port; }) (
          lib.filterAttrs enabled cfg.services.prometheus.exporters
        )
        // lib.optionalAttrs cfg.services.coredns.enable {
          coredns.port = corednsPort cfg.services.coredns.config;
        }
        // lib.optionalAttrs cfg.services.corerad.enable {
          corerad.port = portOf cfg.services.corerad.settings.debug.address;
        }
        // lib.optionalAttrs cfg.services.zrepl.enable {
          zrepl.port = portOf (lib.head cfg.services.zrepl.settings.global.monitoring).listen;
        };
      ssh = cfg.services.openssh.enable;
      router = cfg.services.corerad.enable;
    }
  ) inputs.self.nixosConfigurations;

  # Everything else: machines not managed by this flake, and exporters which
  # aren't NixOS services. alerts = false for PCs which are often off.
  otherHosts = {
    monitnerr-1.jobs = {
      consrv.port = 9288;
      node.port = 9100;
    };
    nerr-4 = {
      jobs = {
        apcupsd.port = 9162;
        node.port = 9100;
      };
      ssh = true;
      alerts = false;
    };
    # Prusa exporter: https://github.com/pstrobl96/prusa_exporter
    "${hostName}".jobs = {
      prusa_prusalink = {
        port = 10009;
        metrics_path = "/metrics/prusalink";
      };
      prusa_udp = {
        port = 10009;
        metrics_path = "/metrics/udp";
      };
    };
  };

  hosts = lib.recursiveUpdate nixosHosts otherHosts;

  # Blackbox HTTP probe targets: local service health endpoints and devices.
  probes = [
    "http://living-room-myq-hub.iot.ipv4"
    "${alertmanagerUrl}/-/healthy"
    "${grafanaUrl}/api/health"
    "${plexUrl}/identity"
    "${prometheusUrl}/-/healthy"
  ];

  # SNMP targets queried via the cyberpower module. The devices are not
  # reliable enough to alert on.
  snmpCyberpowerJob = "snmp-cyberpower";
  snmpCyberpower = [
    "pdu01.ipv4"
    "ups01.ipv4"
  ];

  # NixOS exporters running on this machine which probe jobs are relabeled
  # through.
  local = exporter: "${hostName}:${toString exporters.${exporter}.port}";

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
    (staticScrape job (lib.mapAttrsToList (host: h: "${host}:${toString h.jobs.${job}.port}") running))
    // lib.optionalAttrs (settings.jobs.${job} ? metrics_path) {
      inherit (settings.jobs.${job}) metrics_path;
    }
  );

  # Hosts with SSH banner probing enabled.
  sshTargets = map (host: "${host}:22") (hostsWhere (h: h.ssh or false));

  alerts = import ./prometheus-alerts.nix {
    inherit lib;
    excludedHosts = hostsWhere (h: !(h.alerts or true));
    excludedJobs = [ snmpCyberpowerJob ];
    routers = hostsWhere (h: h.router or false);
  };

  # Scrape a list of static targets for a job.
  staticScrape = job_name: targets: {
    inherit job_name;
    static_configs = [ { inherit targets; } ];
  };

  # Scrape targets through a blackbox exporter module at an interval.
  blackboxScrape = module: interval: targets: {
    job_name = "blackbox_${module}";
    scrape_interval = interval;
    metrics_path = "/probe";
    params.module = [ module ];
    relabel_configs = relabelTarget (local "blackbox");
    static_configs = [ { inherit targets; } ];
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
  # Secrets consumed by prometheus and alertmanager.
  sops.secrets = {
    "alertmanager/discord_webhook_url".restartUnits = [ "alertmanager.service" ];
    "prometheus/homeassistant_token" = {
      owner = "prometheus";
      restartUnits = [ "prometheus.service" ];
    };
  };

  # alertmanager runs with DynamicUser, so hand it the Discord webhook URL via
  # systemd credentials rather than a file owned by a static user.
  systemd.services.alertmanager.serviceConfig.LoadCredential = [
    "discord_webhook_url:${config.sops.secrets."alertmanager/discord_webhook_url".path}"
  ];

  # Prometheus monitoring server and exporter configuration.
  services.prometheus = {
    enable = true;
    webExternalUrl = prometheusUrl;

    # Credential files are not visible to promtool in the build sandbox.
    checkConfig = "syntax-only";

    globalConfig.scrape_interval = "15s";

    alertmanager = {
      enable = true;
      webExternalUrl = alertmanagerUrl;

      configuration = {
        route = {
          group_by = [ "alertname" ];
          group_wait = "10s";
          group_interval = "10s";
          repeat_interval = "1h";
          receiver = "default";
        };
        receivers = [
          {
            name = "default";
            discord_configs = [
              { webhook_url_file = "/run/credentials/alertmanager.service/discord_webhook_url"; }
            ];
          }
        ];
      };
    };

    # Use the alertmanager running on this machine.
    alertmanagers = [
      {
        static_configs = [
          { targets = [ "${hostName}:${toString config.services.prometheus.alertmanager.port}" ]; }
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
              ssh_banner = {
                prober = "tcp";
                tcp.query_response = [ { expect = "^SSH-2.0-"; } ];
              };
            };
          }
        );
      };

      # SNMP exporter with data file from release 0.26.0.
      snmp = {
        enable = true;
        configurationPath = builtins.fetchurl {
          url = "https://raw.githubusercontent.com/prometheus/snmp_exporter/44f8732988e726bad3f13d5779f1da7705178642/snmp.yml";
          sha256 = "01pq2kadrjrzp33qigvv8gxj4vxbsxmi790d07hij45bich6jyar";
        };
      };
    };

    scrapeConfigs = lib.attrValues exporterJobs ++ [
      # Home Assistant requires a more custom configuration.
      {
        job_name = "homeassistant";
        metrics_path = "/api/prometheus";
        authorization.credentials_file = config.sops.secrets."prometheus/homeassistant_token".path;
        static_configs = [ { targets = [ "hass:8123" ]; } ];
      }

      # Blackbox probes for HTTP endpoints.
      (blackboxScrape "http_2xx" "15s" probes)
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
          relabel_configs = relabelTarget (local "snmp");
        }
      ])
    ];

    rules = [ (builtins.toJSON alerts) ];
  };
}
