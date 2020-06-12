{
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
        alert = "CoreRADAdvertiserReceivedInconsistentRouterAdvertisement";
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
}
