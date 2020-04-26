{ config, ... }:

{
  # Prometheus monitoring server and exporter configuration.
  services.prometheus = {
    enable = true;
    webExternalUrl = "https://prometheus.servnerr.com";

    # Use alertmanager running on monitoring machine.
    alertmanagers =
      [{ static_configs = [{ targets = [ "monitnerr-1:9093" ]; }]; }];

    exporters = {
      # Node exporter already enabled on all machines.
      
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

    scrapeConfigs = [
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
        relabel_configs = [
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
            replacement = "servnerr-3:9116";
          }
        ];
        static_configs = [{
          targets =
            [ "switch-livingroom01" "switch-office01" "ap-livingroom02" ];
        }];
      }
    ];
  };
}
