# Prometheus alerting rules. Host and job specifics come from the inventory in
# prometheus.nix rather than being hardcoded here.
{
  lib,
  # Hosts which don't run 24/7 and should never raise down alerts.
  excludedHosts,
  # Jobs whose targets are too unreliable to raise down alerts.
  excludedJobs,
  # Hosts acting as routers, whose CoreRAD default route comes from the WAN.
  routers,
}:

let
  # Regular expressions are emitted as PromQL raw strings (backticks) so that
  # escaped characters survive.
  raw = s: "`${s}`";
  anyOf = xs: lib.concatMapStringsSep "|" lib.escapeRegex xs;

  # Matches an instance label ("host:port", or a probe URL) for any of hosts.
  hostsRegex = hosts: raw "(${anyOf hosts}):.*";

  excludedInstances = hostsRegex excludedHosts;
  routerInstances = hostsRegex routers;
  excludedJobsRegex = raw (anyOf excludedJobs);
in
{
  groups = [
    {
      name = "default";
      rules = [
        # Always firing; routed to an external heartbeat so that silence from
        # this Prometheus and Alertmanager pair is itself noticed.
        {
          alert = "Watchdog";
          expr = "vector(1)";
          annotations.summary = "Prometheus and Alertmanager on {{ $externalURL }} are alive.";
        }
        {
          alert = "InstanceDown";
          expr = "up{instance!~${excludedInstances},job!~${excludedJobsRegex}} == 0";
          for = "5m";
          annotations.summary = "{{ $labels.instance }} of job {{ $labels.job }} has been down for more than 5 minutes.";
        }
        {
          alert = "ServiceDown";
          expr = "probe_success{instance!~${excludedInstances},job!~${excludedJobsRegex}} == 0";
          for = "5m";
          annotations.summary = "{{ $labels.instance }} of job {{ $labels.job }} has been down for more than 5 minutes.";
        }
        # Any failed systemd unit, on any machine: this covers failed nightly
        # upgrades, sops secrets, and services which died after a switch.
        {
          alert = "SystemdUnitFailed";
          expr = ''node_systemd_unit_state{state="failed"} == 1'';
          for = "5m";
          annotations.summary = "Unit {{ $labels.name }} on {{ $labels.instance }} has failed.";
        }
        {
          alert = "SmartStatusFailed";
          expr = "smartctl_device_smart_status == 0";
          for = "5m";
          annotations.summary = "Disk {{ $labels.device }} ({{ $labels.model_name }}, {{ $labels.serial_number }}) on {{ $labels.instance }} reports SMART failure.";
        }
        {
          alert = "SmartCriticalWarning";
          expr = "smartctl_device_critical_warning > 0";
          for = "5m";
          annotations.summary = "NVMe {{ $labels.device }} on {{ $labels.instance }} reports a critical warning.";
        }
        {
          alert = "ZFSPoolUnhealthy";
          # 0 is ONLINE; anything greater is DEGRADED, FAULTED, OFFLINE,
          # UNAVAIL, REMOVED, or SUSPENDED.
          expr = "zfs_pool_health > 0";
          for = "5m";
          annotations.summary = "ZFS pool {{ $labels.pool }} on {{ $labels.instance }} is unhealthy.";
        }
        {
          alert = "DiskUsageHigh";
          expr = ''(1 - node_filesystem_free_bytes{fstype=~"ext4|vfat"} / node_filesystem_size_bytes) > 0.75'';
          for = "1m";
          annotations.summary = "Disk usage on {{ $labels.instance }}:{{ $labels.mountpoint }} ({{ $labels.device }}) exceeds 75%.";
        }
        {
          alert = "APCUPSOnBattery";
          expr = "apcupsd_battery_time_on_seconds > 0";
          annotations.summary = "UPS on {{ $labels.instance }} is running on battery power.";
        }
        {
          alert = "APCUPSBatteryTimeLeft";
          expr = "apcupsd_battery_time_on_seconds > 0 and apcupsd_battery_time_left_seconds < 30*60";
          annotations.summary = "UPS on {{ $labels.instance }} has less than 30 minutes of remaining battery runtime.";
        }
        # All advertising interfaces should be forwarding IPv6 traffic, and
        # have IPv6 autoconfiguration disabled.
        {
          alert = "CoreRADAdvertisingInterfaceMisconfigured";
          expr = "(corerad_interface_advertising == 1) and ((corerad_interface_forwarding == 0) or (corerad_interface_autoconfiguration == 1))";
          for = "1m";
          annotations.summary = "CoreRAD ({{ $labels.instance }}) interface {{ $labels.interface }} is misconfigured for sending IPv6 router advertisements.";
        }
        # All CoreRAD interfaces should multicast IPv6 RAs on a regular basis
        # so hosts don't drop their default route.
        {
          alert = "CoreRADAdvertiserNotMulticasting";
          expr = ''rate(corerad_advertiser_router_advertisements_total{type="multicast"}[20m]) == 0'';
          for = "1m";
          annotations.summary = "CoreRAD ({{ $labels.instance }}) interface {{ $labels.interface }} has not sent a multicast router advertisment in more than 20 minutes.";
        }
        # Monitor for inconsistent advertisements from hosts on the LAN.
        {
          alert = "CoreRADAdvertiserReceivedInconsistentRouterAdvertisement";
          expr = "rate(corerad_advertiser_router_advertisement_inconsistencies_total[5m]) > 0";
          annotations.summary = "CoreRAD ({{ $labels.instance }}) interface {{ $labels.interface }} received an IPv6 router advertisement with inconsistent configuration compared to its own.";
        }
        # Every interface advertises exactly 2 prefixes: one GUA and one ULA.
        {
          alert = "CoreRADAdvertiserMissingPrefix";
          expr = "count by(instance, interface) (corerad_advertiser_prefix_autonomous == 1) != 2";
          for = "1m";
          annotations.summary = "CoreRAD ({{ $labels.instance }}) interface {{ $labels.interface }} is advertising an incorrect number of IPv6 prefixes for SLAAC.";
        }
        # All IPv6 prefixes are advertised with SLAAC.
        {
          alert = "CoreRADAdvertiserPrefixNotAutonomous";
          expr = "corerad_advertiser_prefix_autonomous == 0";
          for = "1m";
          annotations.summary = "CoreRAD ({{ $labels.instance }}) prefix {{ $labels.prefix }} on interface {{ $labels.interface }} is not configured for SLAAC.";
        }
        # Expect regular upstream router advertisements.
        {
          alert = "CoreRADMonitorNoUpstreamRouterAdvertisements";
          expr = ''changes(corerad_monitor_messages_received_total{message="router advertisement"}[30m]) == 0'';
          annotations.summary = "CoreRAD ({{ $labels.instance }}) interface {{ $labels.interface }} has not received a router advertisement from {{ $labels.host }} in more than 30 minutes.";
        }
        # Ensure the default route does not expire. The LAN default route uses a
        # much lower threshold.
        {
          alert = "CoreRADMonitorDefaultRouteWANExpiring";
          expr = "corerad_monitor_default_route_expiration_timestamp_seconds{instance=~${routerInstances}} - time() < 2*60*60";
          annotations.summary = "CoreRAD ({{ $labels.instance }}) interface {{ $labels.interface }} will drop its default route to WAN {{ $labels.router }} in less than 2 hours.";
        }
        {
          alert = "CoreRADMonitorDefaultRouteLANExpiring";
          expr = "corerad_monitor_default_route_expiration_timestamp_seconds{instance!~${routerInstances}} - time() < 1*60*10";
          annotations.summary = "CoreRAD ({{ $labels.instance }}) interface {{ $labels.interface }} will drop its default route to LAN {{ $labels.router }} in less than 10 minutes.";
        }
      ];
    }
  ];
}
