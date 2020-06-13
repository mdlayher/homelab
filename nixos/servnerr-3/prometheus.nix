{ pkgs, lib, ... }:

let
  secrets = import ./lib/secrets.nix;

  # Scrape a target with the specified module, interval, and list of targets.
  blackboxScrape = (module: blackboxScrapeJobName module module);

  # Same as blackboxScrape, but allow customizing the job name.
  blackboxScrapeJobName = (job: module: interval: targets: {
    job_name = "blackbox_${job}";
    scrape_interval = "${interval}";
    metrics_path = "/probe";
    params = { module = [ "${module}" ]; };
    # blackbox_exporter location is hardcoded.
    relabel_configs = relabelTarget "servnerr-3:9115";
    static_configs = [{ inherit targets; }];
  });

  # Scrape a list of static targets for a job.
  staticScrape = (job: targets: {
    job_name = job;
    static_configs = [{ inherit targets; }];
  });

  # Produces a relabeling configuration that replaces the instance label with
  # the HTTP target parameter.
  relabelTarget = (target: [
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
  ]);

in {
  # Prometheus monitoring server and exporter configuration.
  services.prometheus = {
    enable = true;
    webExternalUrl = "https://prometheus.servnerr.com";

    globalConfig.scrape_interval = "15s";

    extraFlags = [ "--storage.tsdb.retention=365d" "--web.enable-admin-api" ];

    alertmanager = {
      enable = true;
      webExternalUrl = "https://alertmanager.servnerr.com";

      configuration = {
        route = {
          group_by = [ "alertname" ];
          group_wait = "10s";
          group_interval = "10s";
          repeat_interval = "1h";
          receiver = "default";
        };
        receivers = [{
          name = "default";
          pushover_configs = secrets.alertmanager.pushover;
        }];
      };
    };

    # Use alertmanager running on monitoring machine.
    alertmanagers =
      [{ static_configs = [{ targets = [ "servnerr-3:9093" ]; }]; }];

    exporters = {
      # Node exporter already enabled on all machines.

      apcupsd.enable = true;

      blackbox = {
        enable = true;
        configFile = pkgs.writeText "blackbox.yml" (builtins.toJSON ({
          modules = {
            http_2xx.prober = "http";
            http_401 = {
              prober = "http";
              http.valid_status_codes = [ 401 ];
            };
            ssh_banner = {
              prober = "tcp";
              tcp.query_response = [{ expect = "^SSH-2.0-"; }];
            };
          };
        }));
      };

      keylight.enable = true;

      # SNMP exporter with data file from release 0.18.0.
      snmp = {
        enable = true;
        configurationPath = builtins.fetchurl {
          url =
            "https://raw.githubusercontent.com/prometheus/snmp_exporter/9a2ff257dd2e8cdb2a4c88b18df668e2008c2cd6/snmp.yml";
          sha256 = "10pvs9b49p5xnh7q2dfm268mhx5q3d7xp6j8qaljipcrsls8ddfm";
        };
      };
    };

    # TODO: template out hostnames or consider DNSSD.
    scrapeConfigs = [
      # Simple, static scrape jobs.
      (staticScrape "apcupsd" [
        "nerr-3:9162"
        "routnerr-2:9162"
        "servnerr-3:9162"
      ])
      (staticScrape "coredns" [ "routnerr-2:9153" ])
      (staticScrape "corerad" [ "routnerr-2:9430" ])
      (lib.mkMerge [
        (staticScrape "keylight" [ "keylight" ])
        { relabel_configs = relabelTarget "servnerr-3:9288"; }
      ])
      (staticScrape "node" [
        "monitnerr-1:9100"
        "nerr-3:9100"
        "routnerr-2:9100"
        "servnerr-3:9100"
      ])
      (staticScrape "obs" [ "nerr-3:9407" ])
      (staticScrape "wireguard" [ "routnerr-2:9586" ])

      # Blackbox exporter and associated targets.
      (staticScrape "blackbox" [ "servnerr-3:9115" ])
      (blackboxScrape "http_2xx" "15s" [ "https://grafana.servnerr.com" ])
      # Netlify can occasionally be flappy, so check it less often.
      (blackboxScrapeJobName "http_2xx_mdlayhercom" "http_2xx" "1m"
        [ "https://mdlayher.com" ])
      (blackboxScrape "http_401" "15s" [
        "https://alertmanager.servnerr.com"
        "https://plex.servnerr.com"
        "https://prometheus.servnerr.com"
      ])
      # The SSH banner check produces a fair amount of log spam, so only scrape
      # it once a minute.
      (blackboxScrape "ssh_banner" "1m" [
        "monitnerr-1:22"
        "nerr-3:22"
        "routnerr-2:22"
        "servnerr-3:22"
      ])

      # SNMP relabeling configuration required to properly replace the instance
      # names and query the correct devices.
      (lib.mkMerge [
        (staticScrape "snmp" [
          "switch-livingroom01"
          "switch-office01"
          "switch-office02.ipv4"
          "ap-livingroom02.ipv4"
        ])
        {
          metrics_path = "/snmp";
          params = { module = [ "if_mib" ]; };
          relabel_configs = relabelTarget "servnerr-3:9116";
        }
      ])

      # Lab-only jobs must be prefixed with lab- to avoid alerting.
      (staticScrape "lab-corerad" [ "routnerr-2:9431" ])
    ];

    rules = [ (builtins.toJSON (import ./prometheus-alerts.nix)) ];
  };
}
