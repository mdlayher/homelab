{ pkgs, ... }:

let
  # Scrape a target with the specified module, interval, and list of targets.
  blackboxScrape = (module:
    blackboxScrapeJobName module module);

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

  # Produces a relabeling configuration that replaces the instance label with
  # the HTTP target parameter.
  relabelTarget = (target: [
    {
      source_labels = [ "__address__" ];
      target_label = "__param_target";
    }
    {
      source_labels = [ "__param_target__" ];
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

    # Use alertmanager running on monitoring machine.
    alertmanagers =
      [{ static_configs = [{ targets = [ "monitnerr-1:9093" ]; }]; }];

    exporters = {
      # Node exporter already enabled on all machines.

      blackbox = {
        enable = true;
        configFile = pkgs.writeText "blackbox.yml" ''
          modules:
            http_2xx:
              prober: http
            http_401:
              prober: http
              http:
                valid_status_codes: [401]
            ssh_banner:
              prober: tcp
              tcp:
                query_response:
                - expect: "^SSH-2.0-"
                  '';
      };

      # SNMP exporter with data file from release 0.17.0.
      snmp = {
        enable = true;
        configurationPath = builtins.fetchurl {
          url =
            "https://raw.githubusercontent.com/prometheus/snmp_exporter/f0ad4551a5c2023e383bc8dde2222f47dc760b83/snmp.yml";
          sha256 =
            "5c1febe100ce9140c8c59cf3c2a6346a1219dd0966d5cd2926498e88dcd69997";
        };
      };
    };

    # TODO: template out hostnames or consider DNSSD.
    scrapeConfigs = [
      # Blackbox exporter and associated targets.
      {
        job_name = "blackbox";
        static_configs = [{ targets = [ "servnerr-3:9115" ]; }];
      }
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
        "unifi.servnerr.com:22"
      ])
      {
        job_name = "coredns";
        static_configs = [{ targets = [ "routnerr-2:9153" ]; }];
      }
      {
        job_name = "corerad";
        static_configs = [{ targets = [ "routnerr-2:9430" ]; }];
      }
      {
        job_name = "node";
        static_configs = [{
          targets = [
            "monitnerr-1:9100"
            "nerr-3:9100"
            "routnerr-2:9100"
            "servnerr-3:9100"
          ];
        }];
      }
      # SNMP relabeling configuration required to properly replace the instance
      # names and query the correct devices.
      {
        job_name = "snmp";
        metrics_path = "/snmp";
        params = { module = [ "if_mib" ]; };
        relabel_configs = relabelTarget "servnerr-3:9116";
        static_configs = [{
          targets =
            [ "switch-livingroom01" "switch-office01" "ap-livingroom02" ];
        }];
      }
    ];
  };
}
