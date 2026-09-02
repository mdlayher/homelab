# Prometheus alerting rules, sorted alphabetically by alert name. Host and
# job specifics come from the inventory in prometheus.nix rather than being
# hardcoded here.
{
  lib,
  # Hosts which don't run 24/7 and should never raise down alerts.
  excludedHosts,
  # Jobs whose targets are too unreliable to raise down alerts.
  excludedJobs,
  # Hosts acting as routers, whose CoreRAD default route comes from the WAN.
  routers,
  # Hosts expected to ship their journals to Loki.
  logHosts,
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
        # The complement of LokiHostLogsStalled: a shipper that is alive but
        # dropping some lines never goes fully silent, and drops are
        # permanent log loss. Steady state on every host is zero; write
        # retries that eventually succeed are fine and not counted here.
        {
          alert = "AlloyDroppingLogEntries";
          expr = "sum by (instance) (increase(loki_write_dropped_entries_total[1h])) > 0";
          annotations.summary = "Alloy on {{ $labels.instance }} dropped {{ $value | humanize }} log entries bound for Loki in the last hour.";
        }
        {
          alert = "APCUPSBatteryTimeLeft";
          expr = "apcupsd_battery_time_on_seconds > 0 and apcupsd_battery_time_left_seconds < 30*60";
          annotations.summary = "UPS on {{ $labels.instance }} has less than 30 minutes of remaining battery runtime.";
        }
        {
          alert = "APCUPSOnBattery";
          expr = "apcupsd_battery_time_on_seconds > 0";
          annotations.summary = "UPS on {{ $labels.instance }} is running on battery power.";
        }
        # BlackboxServiceDown only sees a probe hard down for 5 straight
        # minutes; sustained partial packet loss never trips it. Probes run
        # every 15s, so the 15m window holds ~60 samples and 0.9 means over
        # 10% loss. The family label comes from the ICMP scrape job's
        # relabeling, and distinguishes a degraded v4 path from a degraded v6
        # path to the same anchors.
        {
          alert = "BlackboxPacketLoss";
          expr = ''avg_over_time(probe_success{job="blackbox_icmp"}[15m]) < 0.9'';
          for = "10m";
          annotations.summary = "{{ $labels.instance }} ({{ $labels.family }}) answered only {{ $value | humanizePercentage }} of ICMP probes over 15 minutes.";
        }
        {
          alert = "BlackboxServiceDown";
          expr = "probe_success{instance!~${excludedInstances},job!~${excludedJobsRegex}} == 0";
          for = "5m";
          annotations.summary = "{{ $labels.instance }} of job {{ $labels.job }} has been down for more than 5 minutes.";
        }
        # The dns_lan probe resolves a name CoreDNS answers from local data,
        # so a broken upstream forwarder passes that probe while every real
        # internet lookup on the LAN fails. The router serves roughly 1 qps,
        # so 5% over 10 minutes is ~30 SERVFAILs; the steady-state ratio is
        # zero.
        {
          alert = "CoreDNSUpstreamFailing";
          expr = ''sum by (instance) (rate(coredns_dns_responses_total{rcode="SERVFAIL"}[10m])) / sum by (instance) (rate(coredns_dns_responses_total[10m])) > 0.05'';
          for = "10m";
          annotations.summary = "CoreDNS on {{ $labels.instance }} returned SERVFAIL for over 5% of DNS queries in the last 10 minutes.";
        }
        # Every interface advertises exactly 2 prefixes: one GUA and one ULA.
        {
          alert = "CoreRADAdvertiserMissingPrefix";
          expr = "count by(instance, interface) (corerad_advertiser_prefix_autonomous == 1) != 2";
          for = "1m";
          annotations.summary = "CoreRAD ({{ $labels.instance }}) interface {{ $labels.interface }} is advertising an incorrect number of IPv6 prefixes for SLAAC.";
        }
        # All CoreRAD interfaces should multicast IPv6 RAs on a regular basis
        # so hosts don't drop their default route.
        {
          alert = "CoreRADAdvertiserNotMulticasting";
          expr = ''rate(corerad_advertiser_router_advertisements_total{type="multicast"}[20m]) == 0'';
          for = "1m";
          annotations.summary = "CoreRAD ({{ $labels.instance }}) interface {{ $labels.interface }} has not sent a multicast router advertisment in more than 20 minutes.";
        }
        # All IPv6 prefixes are advertised with SLAAC.
        {
          alert = "CoreRADAdvertiserPrefixNotAutonomous";
          expr = "corerad_advertiser_prefix_autonomous == 0";
          for = "1m";
          annotations.summary = "CoreRAD ({{ $labels.instance }}) prefix {{ $labels.prefix }} on interface {{ $labels.interface }} is not configured for SLAAC.";
        }
        # Monitor for inconsistent advertisements from hosts on the LAN.
        {
          alert = "CoreRADAdvertiserReceivedInconsistentRouterAdvertisement";
          expr = "rate(corerad_advertiser_router_advertisement_inconsistencies_total[5m]) > 0";
          annotations.summary = "CoreRAD ({{ $labels.instance }}) interface {{ $labels.interface }} received an IPv6 router advertisement with inconsistent configuration compared to its own.";
        }
        # All advertising interfaces should be forwarding IPv6 traffic, and
        # have IPv6 autoconfiguration disabled.
        {
          alert = "CoreRADAdvertisingInterfaceMisconfigured";
          expr = "(corerad_interface_advertising == 1) and ((corerad_interface_forwarding == 0) or (corerad_interface_autoconfiguration == 1))";
          for = "1m";
          annotations.summary = "CoreRAD ({{ $labels.instance }}) interface {{ $labels.interface }} is misconfigured for sending IPv6 router advertisements.";
        }
        # Ensure the default routes do not expire. The LAN default route uses
        # a much lower threshold than the WAN one.
        {
          alert = "CoreRADMonitorDefaultRouteLANExpiring";
          expr = "corerad_monitor_default_route_expiration_timestamp_seconds{instance!~${routerInstances}} - time() < 1*60*10";
          annotations.summary = "CoreRAD ({{ $labels.instance }}) interface {{ $labels.interface }} will drop its default route to LAN {{ $labels.router }} in less than 10 minutes.";
        }
        {
          alert = "CoreRADMonitorDefaultRouteWANExpiring";
          expr = "corerad_monitor_default_route_expiration_timestamp_seconds{instance=~${routerInstances}} - time() < 2*60*60";
          annotations.summary = "CoreRAD ({{ $labels.instance }}) interface {{ $labels.interface }} will drop its default route to WAN {{ $labels.router }} in less than 2 hours.";
        }
        # Expect regular upstream router advertisements.
        {
          alert = "CoreRADMonitorNoUpstreamRouterAdvertisements";
          expr = ''changes(corerad_monitor_messages_received_total{message="router advertisement"}[30m]) == 0'';
          annotations.summary = "CoreRAD ({{ $labels.instance }}) interface {{ $labels.interface }} has not received a router advertisement from {{ $labels.host }} in more than 30 minutes.";
        }
        {
          alert = "FilesystemUsageHigh";
          expr = ''(1 - node_filesystem_free_bytes{fstype=~"ext4|vfat"} / node_filesystem_size_bytes) > 0.75'';
          for = "1m";
          annotations.summary = "Disk usage on {{ $labels.instance }}:{{ $labels.mountpoint }} ({{ $labels.device }}) exceeds 75%.";
        }
        # Battery-powered sensors die silently: the entity goes unavailable
        # and its data just stops. The join against the entity registry keeps
        # only sensors assigned to an area of the house, which excludes
        # personal devices (phones, tablets) that run low routinely and
        # charge themselves; assign an area to a new sensor and it is
        # monitored.
        {
          alert = "HomeAssistantBatteryLow";
          expr = ''homeassistant_sensor_battery_percent * on (entity) group_left(area) homeassistant_entity_info{area!=""} < 15'';
          for = "1h";
          annotations.summary = "Home Assistant sensor {{ $labels.friendly_name }} ({{ $labels.area }}) battery is at {{ $value }}%.";
        }
        # Loki's ruler records per-host log line counts into Prometheus (see
        # nixos/servnerr-4/loki.nix); a host absent from the metric has
        # shipped nothing for over an hour, even though its Alloy may still
        # report up. Every host firing at once means the ruler or its remote
        # write path is broken, not the shippers.
        {
          alert = "LokiHostLogsStalled";
          expr = lib.concatMapStringsSep " or " (
            host: ''absent(host:log_lines:count1h{host="${host}"})''
          ) logHosts;
          for = "30m";
          annotations.summary = "{{ $labels.host }} has shipped no logs to Loki for over an hour.";
        }
        # SystemdUnitFailed catches an upgrade run that fails, but a timer
        # that never runs (masked, wedged, or dropped from configuration)
        # fails nothing, and the machine silently stops tracking main. The
        # timer fires nightly, so 26 hours means a missed night; the > 0
        # guard skips a freshly booted host that has not triggered yet.
        {
          alert = "NixOSAutoUpgradeStalled";
          expr = ''(time() - node_systemd_timer_last_trigger_seconds{name="nixos-upgrade.timer"}) > 26*60*60 and node_systemd_timer_last_trigger_seconds{name="nixos-upgrade.timer"} > 0'';
          annotations.summary = "{{ $labels.instance }} has not run nixos-upgrade.timer in over 26 hours.";
        }
        # `nixos-rebuild test` activates a system without recording it in the
        # system profile, so a reboot (or the next nightly upgrade) silently
        # reverts it; `boot` records one the machine is not yet running. The
        # metric comes from each machine's textfile collector; see
        # nixos/modules/system-metrics.nix. An hour is plenty to verify a
        # test deploy and follow it with boot or switch.
        {
          alert = "NixOSSystemUnpersisted";
          expr = "nixos_system_unpersisted == 1";
          for = "1h";
          annotations.summary = "{{ $labels.instance }} has run a system other than its profile's for over an hour: a test deploy a reboot would revert, or a boot deploy awaiting one.";
        }
        # NVMe wear estimate: 100% is the rated endurance, and the value may
        # keep counting past it. 80% leaves months of lead time at current
        # write rates.
        {
          alert = "NVMeWearHigh";
          expr = "smartctl_device_percentage_used >= 80";
          for = "1h";
          annotations.summary = "NVMe {{ $labels.device }} on {{ $labels.instance }} has used {{ $value }}% of its rated write endurance.";
        }
        {
          alert = "PrometheusInstanceDown";
          expr = "up{instance!~${excludedInstances},job!~${excludedJobsRegex}} == 0";
          for = "5m";
          annotations.summary = "{{ $labels.instance }} of job {{ $labels.job }} has been down for more than 5 minutes.";
        }
        # Jobs excluded from PrometheusInstanceDown flap too often for a 5
        # minute window, but a full day of failed scrapes means the target is
        # dead rather than flaky.
        {
          alert = "PrometheusInstanceDownLong";
          expr = "avg_over_time(up{job=~${excludedJobsRegex}}[1d]) == 0";
          annotations.summary = "{{ $labels.instance }} of flaky job {{ $labels.job }} has been down for an entire day.";
        }
        # Always firing; routed to an external heartbeat so that silence from
        # this Prometheus and Alertmanager pair is itself noticed.
        {
          alert = "PrometheusWatchdog";
          expr = "vector(1)";
          annotations.summary = "Prometheus and Alertmanager on {{ $externalURL }} are alive.";
        }
        {
          alert = "SMARTCriticalWarning";
          expr = "smartctl_device_critical_warning > 0";
          for = "5m";
          annotations.summary = "NVMe {{ $labels.device }} on {{ $labels.instance }} reports a critical warning.";
        }
        # Early warning ahead of SMARTCriticalWarning and SMARTStatusFailed:
        # a drive's own SMART verdict flips (and can flap) only once the
        # drive declares failure, while ATA error log entries and NVMe media
        # errors appear earlier and only ever grow. Every healthy drive holds
        # zero of both; NVMe num_err_log_entries is deliberately not used,
        # since it counts thousands of informational entries on healthy
        # drives.
        {
          alert = "SMARTErrorLogGrowing";
          expr = "increase(smartctl_device_error_log_count[1d]) > 0 or increase(smartctl_device_media_errors[1d]) > 0";
          annotations.summary = "Disk {{ $labels.device }} on {{ $labels.instance }} logged new SMART errors in the last day.";
        }
        {
          alert = "SMARTStatusFailed";
          expr = "smartctl_device_smart_status == 0";
          for = "5m";
          annotations.summary = "Disk {{ $labels.device }} ({{ $labels.model_name }}, {{ $labels.serial_number }}) on {{ $labels.instance }} reports SMART failure.";
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
          alert = "TailscaleTLSCertificateExpiringSoon";
          # Tailscale renews service certificates automatically well before
          # expiry, so anything under 7 days means renewal is broken.
          expr = "probe_ssl_earliest_cert_expiry - time() < 7 * 86400";
          for = "1h";
          annotations.summary = "TLS certificate for {{ $labels.instance }} expires in under 7 days.";
        }
        # A full pool cannot receive replication streams, and zrepl's
        # receiver-side pruning only runs after a successful receive, so a
        # full replication target never frees itself. Root datasets only:
        # children share the pool's available space.
        {
          alert = "ZFSPoolOutOfSpace";
          expr = "zfs_dataset_available_bytes{name!~${raw ".*/.*"}} == 0";
          for = "5m";
          annotations.summary = "ZFS pool {{ $labels.pool }} on {{ $labels.instance }} has no available space.";
        }
        {
          alert = "ZFSPoolUnhealthy";
          # 0 is ONLINE; anything greater is DEGRADED, FAULTED, OFFLINE,
          # UNAVAIL, REMOVED, or SUSPENDED.
          expr = "zfs_pool_health > 0";
          for = "5m";
          annotations.summary = "ZFS pool {{ $labels.pool }} on {{ $labels.instance }} is unhealthy.";
        }
        # Early warning before ZFSPoolOutOfSpace: a nearly full pool still
        # has room to act. Root datasets only: children share the pool's
        # available space.
        {
          alert = "ZFSPoolUsageHigh";
          expr = "zfs_dataset_used_bytes{name!~${raw ".*/.*"}} / (zfs_dataset_used_bytes{name!~${raw ".*/.*"}} + zfs_dataset_available_bytes{name!~${raw ".*/.*"}}) > 0.9";
          for = "15m";
          annotations.summary = "ZFS pool {{ $labels.pool }} on {{ $labels.instance }} is over 90% full.";
        }
        # Errors from an attempted replication run. Unreachable targets (the
        # cold backup pools when detached) report -1 from failed planning
        # rather than a positive count, so this only fires when a run reached
        # a filesystem and failed.
        {
          alert = "ZreplReplicationFailing";
          expr = "zrepl_replication_filesystem_errors > 0";
          for = "1h";
          annotations.summary = "zrepl job {{ $labels.zrepl_job }} on {{ $labels.instance }} has had filesystem replication errors for over an hour.";
        }
        # A job which has succeeded since daemon start but then stopped. The
        # timestamp resets to zero on restart, and never-successful jobs (the
        # detached cold pools) stay at zero, so both are excluded here;
        # ZreplReplicationFailing above covers jobs failing outright.
        {
          alert = "ZreplReplicationStalled";
          expr = "(time() - zrepl_replication_last_successful) > 24*60*60 and zrepl_replication_last_successful > 0";
          annotations.summary = "zrepl job {{ $labels.zrepl_job }} on {{ $labels.instance }} has not replicated successfully in over 24 hours.";
        }
      ];
    }
  ];
}
