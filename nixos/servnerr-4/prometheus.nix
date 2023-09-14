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
    relabel_configs = relabelTarget "servnerr-4:9115";
    static_configs = [{ inherit targets; }];
  });

  # Scrape a list of static targets for a job.
  staticScrape = (job_name: targets: {
    inherit job_name;
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

    extraFlags = [ "--storage.tsdb.retention=1825d" "--web.enable-admin-api" ];

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
      [{ static_configs = [{ targets = [ "servnerr-4:9093" ]; }]; }];

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

      # SNMP exporter with data file from release 0.19.0.
      snmp = {
        enable = true;
        configurationPath = builtins.fetchurl {
          url =
            "https://raw.githubusercontent.com/prometheus/snmp_exporter/1964bce321942a73f994813103ed2ca2e432039d/snmp.yml";
          sha256 =
            "sha256:0cshh89ijchi10iqijvmw473hhxf5cdrd1y0502wlwgw4glbis36";
        };
      };
    };

    # TODO: template out hostnames or consider DNSSD.
    scrapeConfigs = [
      # Simple, static scrape jobs.
      (staticScrape "apcupsd" [ "nerr-4:9162" "servnerr-4:9162" ])
      (staticScrape "consrv" [ "monitnerr-1:9288" ])
      (staticScrape "coredns" [ "routnerr-3:9153" ])
      (staticScrape "corerad" [ "routnerr-3:9430" "servnerr-4:9430" ])
      (staticScrape "node" [
        "monitnerr-1:9100"
        "nerr-4:9100"
        "routnerr-3:9100"
        "servnerr-4:9100"
      ])
      (staticScrape "obs" [ "nerr-4:9407" ])
      (staticScrape "windows" [ "theatnerr-2:9182" ])
      (staticScrape "wireguard" [ "routnerr-3:9586" ])
      (staticScrape "zrepl" [ "servnerr-4:9811" ])

      # Home Assistant requires a more custom configuration.
      {
        job_name = "homeassistant";
        metrics_path = "/api/prometheus";
        bearer_token = "${secrets.prometheus.homeassistant_token}";
        static_configs = [{ targets = [ "servnerr-4:8123" ]; }];
      }

      # Blackbox exporter and associated targets.
      (staticScrape "blackbox" [ "servnerr-4:9115" ])
      (blackboxScrape "http_2xx" "15s" [
        "http://living-room-myq-hub.iot.ipv4"
        "https://grafana.servnerr.com"
      ])
      (blackboxScrape "http_401" "15s" [
        "https://alertmanager.servnerr.com"
        "https://plex.servnerr.com"
        "https://prometheus.servnerr.com"
      ])
      # The SSH banner check produces a fair amount of log spam, so only scrape
      # it once a minute.
      (blackboxScrape "ssh_banner" "1m" [
        "nerr-4:22"
        "routnerr-3:22"
        "servnerr-4:22"
      ])

      # SNMP relabeling configuration required to properly replace the instance
      # names and query the correct devices.
      (lib.mkMerge [
        (staticScrape "snmp-cyberpower" [ "pdu01.ipv4" "ups01.ipv4" ])
        {
          metrics_path = "/snmp";
          params = { module = [ "cyberpower" ]; };
          relabel_configs = relabelTarget "servnerr-4:9116";
        }
      ])

      # Lab-only jobs must be prefixed with lab- to avoid alerting.
      (staticScrape "lab-corerad" [ "routnerr-3:9431" ])
    ];

    rules = [ (builtins.toJSON (import ./prometheus-alerts.nix)) ];
  };
}
