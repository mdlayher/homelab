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

  # Internal dn42 sessions and links (see the router's dn42.nix): dn42i_ is
  # the bird protocol prefix, dn42i- the interface prefix. What is on the
  # other end is an implementation under development rather than a service,
  # so it is expected to be down, and to be broken on purpose while someone
  # works on it. The external dn42e_ peers still alert normally.
  internalProtocols = raw "dn42i_.*";
  internalInterfaces = raw "dn42i-.*";

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
        # BFD is opt-in per dn42 peer. The bird exporter reports BFD as
        # per-session metrics rather than as a protocol, so there is no
        # bird_protocol_up{proto="BFD"} to key on; this matches one series
        # per peer that runs it, drawn from bird's own `show bfd sessions`.
        # Sub-second detection is the whole point of BFD, so a session
        # still down after 5 minutes has taken its BGP session with it.
        #
        # Internal links are excluded by interface, which is the only label
        # here carrying the naming convention: the exporter's name label is
        # the BFD protocol's name, not the BGP session's. Exercising a BFD
        # implementation against bird means watching it fail on purpose.
        {
          alert = "BIRDBFDSessionDown";
          expr = "bird_bfd_session_up{interface!~${internalInterfaces}} == 0";
          for = "5m";
          annotations.summary = "BFD session with {{ $labels.ip }} on interface {{ $labels.interface }} ({{ $labels.instance }}) is down.";
        }
        # Internal sessions are excluded for the same reason as in
        # BIRDBGPSessionDown, and doubly here: their import side is closed
        # by design, so an Established one imports zero routes forever.
        # Excluding on the left side alone is enough, since the join can
        # only produce series which survive it.
        #
        # An Established session carrying nothing is invisible to
        # BIRDBGPSessionDown, and the router's dn42 import filters fail
        # closed by design: every route needs a valid ROA, so losing both
        # RTR feeds past their expire window empties the table while the
        # session stays up. An import filter that rejects everything after
        # an edit looks the same. Half an hour is well past the churn of a
        # bird restart or a session reconverging. The join is explicit
        # because the exporter attaches a state label to only one of a BGP
        # protocol's two channels, so a bare `and` matches on it and
        # silently drops the other address family.
        {
          alert = "BIRDBGPNoRoutesImported";
          expr = ''bird_protocol_prefix_import_count{proto="BGP",name!~${internalProtocols}} == 0 and on (instance, name, ip_version) bird_protocol_up{proto="BGP"} == 1'';
          for = "30m";
          annotations.summary = "BGP session {{ $labels.name }} (IPv{{ $labels.ip_version }}) on {{ $labels.instance }} is Established but has imported no routes.";
        }
        # bird reports a BGP protocol as up only once the session reaches
        # Established, and one series exists per protocol and address
        # family, so a peer whose IPv4 channel fails while IPv6 holds still
        # alerts. dn42 peers are hobby routers that reboot without notice;
        # 10 minutes skips the ordinary flap and still catches a tunnel
        # that is really gone.
        #
        # Internal sessions are named dn42i_* on purpose: the exporter
        # passes bird's protocol name through as the name label, so the
        # naming convention is the switch, and a new internal link is
        # covered without anyone remembering to edit this rule. The BGP
        # implementation on the other end runs only while someone is
        # experimenting with it, and a session which is down most of the
        # time is not news.
        {
          alert = "BIRDBGPSessionDown";
          expr = ''bird_protocol_up{proto="BGP",name!~${internalProtocols}} == 0'';
          for = "10m";
          annotations.summary = "BGP session {{ $labels.name }} (IPv{{ $labels.ip_version }}) on {{ $labels.instance }} is not Established.";
        }
        # Every other BIRD alert here is silent while the exporter is,
        # because a failed birdc socket query drops the protocol metrics
        # entirely rather than zeroing them. The scrape half overlaps
        # PrometheusInstanceDown on purpose: this alert names the
        # consequence, that dn42 is unmonitored until it is fixed.
        {
          alert = "BIRDExporterFailing";
          expr = ''up{job="bird"} == 0 or bird_socket_query_success == 0'';
          for = "5m";
          annotations.summary = "The BIRD exporter on {{ $labels.instance }} is failing, so dn42 protocol state is unmonitored.";
        }
        # Two RTR servers feed the same ROA tables, so one down is
        # redundancy doing its job rather than an outage, and the tables
        # hold their data for the two hour expire window. That leaves
        # plenty of room to wait out a refresh or retry cycle before
        # alerting; what this catches ahead of an empty table is the second
        # feed going the same way.
        {
          alert = "BIRDRPKISessionDown";
          expr = ''bird_protocol_up{proto="RPKI"} == 0'';
          for = "30m";
          annotations.summary = "RPKI validator session {{ $labels.name }} on {{ $labels.instance }} is not Established.";
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
        # As with BIRDExporterFailing: a failed scrape drops the handshake
        # metrics rather than zeroing them, so the rule below goes quiet
        # exactly when the exporter does. Overlapping PrometheusInstanceDown
        # is the point, naming the consequence.
        {
          alert = "WireGuardExporterDown";
          expr = ''up{job="wireguard"} == 0'';
          for = "5m";
          annotations.summary = "The WireGuard exporter on {{ $labels.instance }} is down, so dn42 tunnel handshakes are unmonitored.";
        }
        # Nothing else notices a dead dn42 tunnel this quickly: BGP holds for
        # 240 seconds before the session drops, and BIRDBGPSessionDown then
        # waits 10 minutes on top of that. WireGuard rehandshakes roughly
        # every two minutes while traffic flows, and BGP keepalives guarantee
        # traffic, so three minutes of silence means the tunnel is gone
        # rather than idle. That reasoning is specific to dn42 peers, hence
        # the interface match: a future tunnel carrying no keepalives would
        # need its own threshold. The prefix is dn42e- rather than dn42-,
        # since the latter also matches the dn42i- VLANs, which carry no
        # WireGuard at all. A peer which has never handshaken reports a
        # delay measured from the epoch and fires immediately, which is the
        # right answer for a tunnel that never came up. Rates on the byte
        # counters would add nothing: the handshakes are themselves driven by
        # that traffic, so a tunnel whose bytes stop moving goes stale within
        # a handshake interval anyway, and a live tunnel carrying no useful
        # routes is what the BIRD rules above catch.
        {
          alert = "WireGuardPeerHandshakeStale";
          expr = "wireguard_latest_handshake_delay_seconds{interface=~${raw "dn42e-.*"}} > 180";
          for = "5m";
          annotations.summary = "WireGuard tunnel {{ $labels.interface }} on {{ $labels.instance }} last handshook {{ $value | humanizeDuration }} ago.";
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
