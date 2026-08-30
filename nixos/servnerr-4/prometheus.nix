{
  config,
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

  # Exporters which may run on hosts in the inventory below, keyed by job name.
  # Ports for exporters running on this machine come from their NixOS options
  # so they can't drift.
  exporterJobs = {
    apcupsd.port = exporters.apcupsd.port;
    blackbox.port = exporters.blackbox.port;
    consrv.port = 9288;
    coredns.port = 9153;
    corerad.port = 9430;
    node.port = exporters.node.port;
    zrepl.port = zreplPort;

    # Prusa exporter: https://github.com/pstrobl96/prusa_exporter
    prusa_prusalink = {
      port = 10009;
      metrics_path = "/metrics/prusalink";
    };
    prusa_udp = {
      port = 10009;
      metrics_path = "/metrics/udp";
    };
  };

  # Hosts scraped by this Prometheus: which exporter jobs each runs, whether
  # its SSH banner should be probed, whether it runs 24/7 (alerts = false for
  # PCs which are often off), and whether it is a router.
  hosts = {
    "${hostName}" = {
      exporters = [
        "apcupsd"
        "blackbox"
        "node"
        "prusa_prusalink"
        "prusa_udp"
        "zrepl"
      ];
      ssh = true;
    };
    nerr-4 = {
      exporters = [
        "apcupsd"
        "node"
      ];
      ssh = true;
      alerts = false;
    };
    monitnerr-1.exporters = [
      "consrv"
      "node"
    ];
    routnerr-3 = {
      exporters = [
        "coredns"
        "corerad"
        "node"
      ];
      ssh = true;
      router = true;
    };
  };

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

  # zrepl's Prometheus listener is configured in storage.nix as ":port".
  zreplPort = lib.toInt (
    lib.removePrefix ":" (lib.head config.services.zrepl.settings.global.monitoring).listen
  );

  # NixOS exporters running on this machine which probe jobs are relabeled
  # through.
  local = exporter: "${hostName}:${toString exporters.${exporter}.port}";

  # Hosts in the inventory running the given exporter job, as host:port targets.
  targetsFor =
    job:
    lib.mapAttrsToList (host: _: "${host}:${toString exporterJobs.${job}.port}") (
      lib.filterAttrs (_: h: lib.elem job (h.exporters or [ ])) hosts
    );

  # Hosts in the inventory with SSH banner probing enabled.
  sshTargets = lib.mapAttrsToList (host: _: "${host}:22") (
    lib.filterAttrs (_: h: h.ssh or false) hosts
  );

  # Hosts in the inventory matching a predicate, by name.
  hostsWhere = pred: lib.attrNames (lib.filterAttrs (_: pred) hosts);

  alerts = import ./prometheus-alerts.nix {
    inherit lib;
    excludedHosts = hostsWhere (h: !(h.alerts or true));
    excludedJobs = [ snmpCyberpowerJob ];
    routers = hostsWhere (h: h.router or false);
  };

  # Scrape a list of static targets for a job.
  staticScrape = (
    job_name: targets: {
      inherit job_name;
      static_configs = [ { inherit targets; } ];
    }
  );

  # Scrape a target with the specified module, interval, and list of targets.
  blackboxScrape = (module: blackboxScrapeJobName module module);

  # Same as blackboxScrape, but allow customizing the job name.
  blackboxScrapeJobName = (
    job: module: interval: targets: {
      job_name = "blackbox_${job}";
      scrape_interval = "${interval}";
      metrics_path = "/probe";
      params = {
        module = [ "${module}" ];
      };
      relabel_configs = relabelTarget (local "blackbox");
      static_configs = [ { inherit targets; } ];
    }
  );

  # Produces a relabeling configuration that replaces the instance label with
  # the HTTP target parameter.
  relabelTarget = (
    target: [
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
        replacement = "${target}";
      }
    ]
  );

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

    extraFlags = [
      "--storage.tsdb.retention=1825d"
      "--web.enable-admin-api"
    ];

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
          builtins.toJSON ({
            modules = {
              http_2xx.prober = "http";
              ssh_banner = {
                prober = "tcp";
                tcp.query_response = [ { expect = "^SSH-2.0-"; } ];
              };
            };
          })
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

    scrapeConfigs =
      # One static job per exporter, targeting every inventory host running it.
      (lib.mapAttrsToList (
        job: cfg:
        (staticScrape job (targetsFor job))
        // lib.optionalAttrs (cfg ? metrics_path) { inherit (cfg) metrics_path; }
      ) exporterJobs)
      ++ [
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
            params = {
              module = [ "cyberpower" ];
            };
            relabel_configs = relabelTarget (local "snmp");
          }
        ])
      ];

    rules = [ (builtins.toJSON alerts) ];
  };
}
