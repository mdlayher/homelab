{
  groups = [{
    name = "default";
    rules = [
      # PCs which don't run 24/7 are excluded from alerts, and lab-* jobs are
      # excluded due to their experimental nature.
      {
        alert = "InstanceDown";
        expr =
          ''up{instance!~"(nerr-.*|theatnerr-.*)",job!~"lab-.*|snmp-.*"} == 0'';
        for = "5m";
        annotations.summary =
          "{{ $labels.instance }} of job {{ $labels.job }} has been down for more than 5 minutes.";
      }
      {
        alert = "ServiceDown";
        expr =
          ''probe_success{instance!~"nerr-.*",job!~"lab-.*|snmp-.*"} == 0'';
        for = "5m";
        annotations.summary =
          "{{ $labels.instance }} of job {{ $labels.job }} has been down for more than 5 minutes.";
      }
      {
        alert = "TLSCertificateNearExpiration";
        expr = "probe_ssl_earliest_cert_expiry - time() < 60 * 60 * 24 * 2";
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
      {
        alert = "APCUPSOnBattery";
        expr = "apcupsd_battery_time_on_seconds > 0";
        annotations.summary =
          "UPS on {{ $labels.instance }} is running on battery power.";
      }
      {
        alert = "APCUPSBatteryTimeLeft";
        expr =
          "apcupsd_battery_time_on_seconds > 0 and apcupsd_battery_time_left_seconds < 30*60";
        annotations.summary =
          "UPS on {{ $labels.instance }} has less than 30 minutes of remaining battery runtime.";
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
        alert = "CoreRADAdvertiserReceivedInconsistentRouterAdvertisement";
        expr = ''
          rate(corerad_advertiser_router_advertisement_inconsistencies_total{job="corerad"}[5m]) > 0'';
        annotations.summary =
          "CoreRAD ({{ $labels.instance }}) interface {{ $labels.interface }} received an IPv6 router advertisement with inconsistent configuration compared to its own.";
      }
      # We are advertising 2 prefixes per interface out of GUA /56 (assume a
      # static /40) and ULA /48.
      {
        alert = "CoreRADAdvertiserMissingPrefix";
        expr = ''
          (count by(instance, interface) (corerad_advertiser_prefix_autonomous{job="corerad",prefix=~"2600:6c4a:78.*|fd9e:1a04:f01d:.*"} == 1) != bool 2) == 1'';
        for = "1m";
        annotations.summary =
          "CoreRAD ({{ $labels.instance }}) interface {{ $labels.interface }} is advertising an incorrect number of IPv6 prefixes for SLAAC.";
      }
      # All IPv6 prefixes are advertised with SLAAC.
      {
        alert = "CoreRADAdvertiserPrefixNotAutonomous";
        expr = ''corerad_advertiser_prefix_autonomous{job="corerad"} == 0'';
        for = "1m";
        annotations.summary =
          "CoreRAD ({{ $labels.instance }}) prefix {{ $labels.prefix }} on interface {{ $labels.interface }} is not configured for SLAAC.";
      }
      # Expect regular upstream router advertisements.
      {
        alert = "CoreRADMonitorNoUpstreamRouterAdvertisements";
        expr = ''
          changes(corerad_monitor_messages_received_total{job="corerad",message="router advertisement"}[30m]) == 0'';
        annotations.summary =
          "CoreRAD ({{ $labels.instance }}) interface {{ $labels.interface }} has not received a router advertisement from {{ $labels.host }} in more than 30 minutes.";
      }
      # Ensure the default route does not expire. The LAN default route uses a
      # much lower threshold.
      {
        alert = "CoreRADMonitorDefaultRouteWANExpiring";
        expr = ''
          corerad_monitor_default_route_expiration_timestamp_seconds{instance=~"routnerr-.*",job="corerad"} - time() < 2*60*60'';
        annotations.summary =
          "CoreRAD ({{ $labels.instance }}) interface {{ $labels.interface }} will drop its default route to WAN {{ $labels.router }} in less than 2 hours.";
      }
      {
        alert = "CoreRADMonitorDefaultRouteLANExpiring";
        expr = ''
          corerad_monitor_default_route_expiration_timestamp_seconds{instance!~"routnerr-.*",job="corerad"} - time() < 1*60*10'';
        annotations.summary =
          "CoreRAD ({{ $labels.instance }}) interface {{ $labels.interface }} will drop its default route to LAN {{ $labels.router }} in less than 10 minutes.";
      }
    ];
  }];
}
