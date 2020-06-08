{ pkgs, ... }:

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

    extraFlags = [ "--storage.tsdb.retention=365d" ];

    alertmanager = {
      enable = true;
      webExternalUrl = "https://alertmanager.servnerr.com";

      configuration = {
        route = {
          group_by = ["alertname"];
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
      {
        job_name = "apcupsd";
        static_configs = [{ targets = [ "nerr-3:9162" ]; }];
      }
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
        job_name = "keylight";
        relabel_configs = relabelTarget "servnerr-3:9288";
        static_configs = [{ targets = [ "keylight" ]; }];
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
      {
        job_name = "obs";
        static_configs = [{ targets = [ "nerr-3:9407" ]; }];
      }
      # SNMP relabeling configuration required to properly replace the instance
      # names and query the correct devices.
      {
        job_name = "snmp";
        metrics_path = "/snmp";
        params = { module = [ "if_mib" ]; };
        relabel_configs = relabelTarget "servnerr-3:9116";
        static_configs = [{
          targets = [
            "switch-livingroom01"
            "switch-office01"
            "switch-office02.ipv4"
            "ap-livingroom02.ipv4"
          ];
        }];
      }
      {
        job_name = "wireguard";
        static_configs = [{ targets = [ "routnerr-2:9586" ]; }];
      }
      # Lab-only jobs must be prefixed with lab- to avoid alerting.
      {
        job_name = "lab-corerad";
        static_configs = [{ targets = [ "routnerr-2:9431" ]; }];
      }
    ];

    rules = [
      (builtins.toJSON ({
        groups = [{
          name = "default";
          rules = [
            # Desktop PC is excluded from alerts as it isn't running 24/7, and
            # lab-* jobs are excluded due to their experimental nature.
            {
              alert = "InstanceDown";
              expr = ''up{instance!~"nerr-3.*",job!~"lab-.*"} == 0'';
              for = "2m";
              annotations.summary =
                "{{ $labels.instance }} of job {{ $labels.job }} has been down for more than 2 minutes.";
            }
            {
              alert = "ServiceDown";
              expr = ''probe_success{instance!~"nerr-3.*",job!~"lab-.*"} == 0'';
              for = "2m";
              annotations.summary =
                "{{ $labels.instance }} of job {{ $labels.job }} has been down for more than 2 minutes.";
            }
            {
              alert = "TLSCertificateNearExpiration";
              expr =
                "probe_ssl_earliest_cert_expiry - time() < 60 * 60 * 24 * 2";
              for = "1m";
              annotations.summary =
                "TLS certificate for {{ $labels.instance }} will expire in less than 2 days.";
            }
            {
              alert = "DiskUsageHigh";
              expr = ''
                (1 - node_filesystem_free_bytes{fstype=~"ext4|vfat"} / node_filesystem_size_bytes) > 0.75'';
              for = "1m";
              annotations.summary =
                "Disk usage on {{ $labels.instance }}:{{ $labels.mountpoint }} ({{ $labels.device }}) exceeds 75%.";
            }
            # All advertising interfaces should be forwarding IPv6 traffic, and
            # have IPv6 autoconfiguration disabled.
            {
              alert = "CoreRADAdvertisingInterfaceMisconfigured";
              expr = ''
                (corerad_interface_advertising{job="corerad"} == 1) and ((corerad_interface_forwarding == 0) or (corerad_interface_autoconfiguration == 1))'';
              for = "1m";
              annotations.summary =
                "CoreRAD ({{ $labels.instance }}) interface {{ $labels.interface }} is misconfigured for sending IPv6 router advertisements.";
            }
            # All monitoring interfaces should be forwarding IPv6 traffic.
            {
              alert = "CoreRADMonitoringInterfaceMisconfigured";
              expr = ''
                (corerad_interface_monitoring{job="corerad"} == 1) and (corerad_interface_forwarding == 0)'';
              for = "1m";
              annotations.summary =
                "CoreRAD ({{ $labels.instance }}) interface {{ $labels.interface }} is misconfigured for monitoring upstream IPv6 NDP traffic.";
            }
            # All CoreRAD interfaces should multicast IPv6 RAs on a regular basis
            # so hosts don't drop their default route.
            {
              alert = "CoreRADAdvertiserNotMulticasting";
              expr = ''
                rate(corerad_advertiser_router_advertisements_total{job="corerad",type="multicast"}[20m]) == 0'';
              for = "1m";
              annotations.summary =
                "CoreRAD ({{ $labels.instance }}) interface {{ $labels.interface }} has not sent a multicast router advertisment in more than 20 minutes.";
            }
            # Monitor for inconsistent advertisements from hosts on the LAN.
            {
              alert =
                "CoreRADAdvertiserReceivedInconsistentRouterAdvertisement";
              expr = ''
                rate(corerad_advertiser_router_advertisement_inconsistencies_total{job="corerad"}[5m]) > 0'';
              annotations.summary =
                "CoreRAD ({{ $labels.instance }}) interface {{ $labels.interface }} received an IPv6 router advertisement with inconsistent configuration compared to its own.";
            }
            # We are advertising 2 prefixes per interface out of GUA /56 and ULA /48.
            {
              alert = "CoreRADAdvertiserMissingPrefix";
              expr = ''
                count by (instance, interface) (corerad_advertiser_router_advertisement_prefix_autonomous{job="corerad",prefix=~"2600:6c4a:7880:32.*|fd9e:1a04:f01d:.*"} == 1) != 2'';
              for = "1m";
              annotations.summary =
                "CoreRAD ({{ $labels.instance }}) interface {{ $labels.interface }} is advertising an incorrect number of IPv6 prefixes for SLAAC.";
            }
            # All IPv6 prefixes are advertised with SLAAC.
            {
              alert = "CoreRADAdvertiserPrefixNotAutonomous";
              expr = ''
                corerad_advertiser_router_advertisement_prefix_autonomous{job="corerad"} == 0'';
              for = "1m";
              annotations.summary =
                "CoreRAD ({{ $labels.instance }}) prefix {{ $labels.prefix }} on interface {{ $labels.interface }} is not configured for SLAAC.";
            }
            # Expect continuous upstream router advertisements.
            {
              alert = "CoreRADMonitorNoUpstreamRouterAdvertisements";
              expr = ''
                rate(corerad_monitor_messages_received_total{job="corerad",message="router advertisement"}[5m]) == 0'';
              annotations.summary =
                "CoreRAD ({{ $labels.instance }}) interface {{ $labels.interface }} has not received a router advertisement from {{ $labels.host }} in more than 5 minutes.";
            }
            # Expect continuous upstream router advertisements.
            {
              alert = "CoreRADMonitorDefaultRouteExpiring";
              expr = ''
                corerad_monitor_default_route_expiration_time{job="corerad"} - time() < 2*60*60'';
              annotations.summary =
                "CoreRAD ({{ $labels.instance }}) interface {{ $labels.interface }} will drop its default route to {{ $labels.router }} in less than 2 hours.";
            }
          ];
        }];
      }))
    ];
  };

  # Out-of-tree exporters.
  services.keylight_exporter.enable = true;
}
