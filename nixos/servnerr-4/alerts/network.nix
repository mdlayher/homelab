# Network services: the WAN link, router advertisements (CoreRAD), DNS
# (CoreDNS), time (chrony, the kernel's view on the timesyncd hosts, w32time
# on the Windows PCs, Glasshouse on the TVs), DHCP leases, the blackbox
# probes, and TLS certificates.
{
  raw,
  internalInterfaces,
  excludedInstances,
  routerInstances,
  excludedJobsRegex,
  ...
}:

{
  name = "network";
  rules = [
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
    {
      alert = "ChronyExporterFailing";
      expr = ''up{job="chrony"} == 0 or chrony_up == 0'';
      for = "5m";
      annotations.summary = "The chrony exporter on {{ $labels.instance }} is failing, so the clock every machine here follows is unmonitored.";
    }
    # An unsynchronised chronyd reports stratum 0 and a null reference
    # id: it is free running on the local oscillator, and the drift it
    # accumulates reaches every machine which takes its time from here.
    # Long enough to sit out a boot, where it starts this way.
    {
      alert = "ChronyNoSelectedSource";
      expr = "chrony_tracking_stratum == 0";
      for = "15m";
      annotations.summary = "chrony on {{ $labels.instance }} has no selected time source and is free running.";
    }
    # Steady state is under a millisecond, so 50ms is a long way out while
    # still far short of what breaks a TLS validity window or a WireGuard
    # handshake timestamp. Slewing back from a real excursion is gradual
    # by design, hence the window.
    {
      alert = "ChronyOffsetHigh";
      expr = "abs(chrony_tracking_last_offset_seconds) > 0.05";
      for = "15m";
      annotations.summary = "chrony on {{ $labels.instance }} is {{ $value | humanizeDuration }} away from its selected time source.";
    }
    # The NTS sources and the unauthenticated fallback pool look alike in
    # these metrics, and authselectmode prefer marks an excluded pool
    # source exactly as it marks a dead one, so source state cannot tell a
    # silent fall back to pool time from normal operation. Reachability
    # can: NTS failing, on an expired certificate or a blocked NTS-KE,
    # stops those sources yielding samples at all. A ratio rather than a
    # count, so the rule survives editing the server list.
    {
      alert = "ChronySourcesUnreachable";
      expr = "count by (instance) (chrony_sources_reachability_success == 1) / count by (instance) (chrony_sources_reachability_success) < 0.7";
      for = "30m";
      annotations.summary = "Only {{ $value | humanizePercentage }} of chrony's time sources on {{ $labels.instance }} are answering.";
    }
    # The hosts on systemd-timesyncd have no chrony metrics; node_exporter
    # reports the kernel's own view instead. The kernel grows its error
    # bound at 500 ppm between successful syncs and caps it at 16 s once it
    # declares the clock unsynchronised, so 8 s is several hours without a
    # sync. chronyd keeps the bound under a second on its hosts, so the rule
    # holds across both. The offset bar matches ChronyOffsetHigh; chrony
    # hosts report zero here because chronyd steers the clock itself.
    {
      alert = "NodeClockUnsynchronised";
      expr = "node_timex_maxerror_seconds{instance!~${excludedInstances}} > 8";
      for = "15m";
      annotations.summary = "The kernel clock on {{ $labels.instance }} carries an error bound of {{ $value | humanizeDuration }}: no successful time sync for hours.";
    }
    {
      alert = "NodeClockOffsetHigh";
      expr = "abs(node_timex_offset_seconds{instance!~${excludedInstances}}) > 0.05";
      for = "15m";
      annotations.summary = "The kernel clock on {{ $labels.instance }} is {{ $value | humanizeDuration }} away from its time source.";
    }
    # w32time on the Windows PCs polls hourly and steers coarsely, so tens
    # of milliseconds is its steady state; a second is not. The PCs sit
    # outside the down alerts, but a clock rule only fires while a PC is up
    # and scraped, so it needs no exclusion. The sync source series is one
    # per source type, and NTP is the only type that is a real time source.
    {
      alert = "WindowsClockUnsynchronised";
      expr = ''windows_time_clock_sync_source{type="NTP"} == 0'';
      for = "15m";
      annotations.summary = "w32time on {{ $labels.instance }} is not taking time from NTP.";
    }
    {
      alert = "WindowsClockOffsetHigh";
      expr = "abs(windows_time_computed_time_offset_seconds) > 1";
      for = "15m";
      annotations.summary = "w32time on {{ $labels.instance }} is {{ $value | humanizeDuration }} away from its time source.";
    }
    # The TVs take time from Glasshouse's SNTP client alone, since LG's time
    # service is blocked; it polls hourly and steps the clock past a second
    # of error. A TV resuming from its overnight suspend reports the answer
    # it had before sleeping until the next hourly poll, so the age climbs
    # past the length of the suspend every morning; the bar sits above a
    # night of that. The series exists only while a TV is scraped, and the
    # job label routes the alert through the TVs' overnight mute.
    {
      alert = "GlasshouseClockStale";
      expr = "time() - glasshouse_ntp_last_answer_timestamp_seconds > 8 * 3600";
      for = "15m";
      annotations.summary = "Glasshouse on {{ $labels.instance }} has had no NTP answer for {{ $value | humanizeDuration }}, so the TV's clock is free running.";
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
    # Every site LAN advertises exactly 2 prefixes: one GUA and one ULA.
    # The internal dn42 VLANs have their own rule below.
    {
      alert = "CoreRADAdvertiserMissingPrefix";
      expr = "count by(instance, interface) (corerad_advertiser_prefix_autonomous{interface!~${internalInterfaces}} == 1) != 2";
      for = "1m";
      annotations.summary = "CoreRAD ({{ $labels.instance }}) interface {{ $labels.interface }} is advertising an incorrect number of IPv6 prefixes for SLAAC.";
    }
    # An internal dn42 VLAN advertises exactly 1 prefix, its dn42 /64
    # (see the router's corerad.nix). Anchored on the advertising
    # interface rather than on the prefix count alone, so an interface
    # advertising no prefix at all, which has no count to compare, is
    # caught too.
    {
      alert = "CoreRADDN42AdvertiserMissingPrefix";
      expr = "corerad_interface_advertising{interface=~${internalInterfaces}} == 1 unless on (instance, interface) count by (instance, interface) (corerad_advertiser_prefix_autonomous == 1) == 1";
      for = "1m";
      annotations.summary = "CoreRAD ({{ $labels.instance }}) internal dn42 interface {{ $labels.interface }} is not advertising exactly one IPv6 prefix for SLAAC.";
    }
    # All CoreRAD interfaces should multicast IPv6 RAs on a regular basis
    # so hosts don't drop their default route.
    {
      alert = "CoreRADAdvertiserNotMulticasting";
      expr = ''rate(corerad_advertiser_router_advertisements_total{type="multicast"}[20m]) == 0'';
      for = "1m";
      annotations.summary = "CoreRAD ({{ $labels.instance }}) interface {{ $labels.interface }} has not sent a multicast router advertisment in more than 20 minutes.";
    }
    # An ISP renumber invalidates the whole IPv6 layout at once: every
    # gua_prefix in the inventory secrets, the addresses rendered into
    # the firewall's sets and networkd's drop-ins, and the AAAA records
    # CoreDNS serves all go stale together, silently. Nothing else here
    # notices, because each individual piece stays internally
    # consistent.
    #
    # No new exporter is needed to see it. CoreRAD already publishes
    # every advertised prefix as a label, and
    # CoreRADAdvertiserMissingPrefix above establishes the invariant
    # this leans on: exactly two prefixes per interface, one GUA and
    # one ULA. A renumber replaces the GUA, so for the length of the
    # lookback both the old and the new prefix have samples in the
    # window and the interface's distinct count goes to three. Counting
    # per interface rather than per router means there is no total to
    # keep in step as interfaces come and go.
    #
    # The alert clears on its own once the old prefix ages out of the
    # window, which is the right shape: this reports an event, and the
    # work it implies is updating the inventory secrets.
    {
      alert = "CoreRADAdvertiserPrefixChanged";
      expr = "count by (instance, interface) (count by (instance, interface, prefix) (last_over_time(corerad_advertiser_prefix_on_link[6h]))) > 2";
      for = "15m";
      annotations.summary = "CoreRAD ({{ $labels.instance }}) interface {{ $labels.interface }} has advertised {{ $value }} distinct prefixes in 6 hours; the ISP may have renumbered the delegation.";
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
    # An unknown management LAN host still takes a lease (see the
    # router's network-snapshot.nix). A mistyped inventory MAC
    # shows here too.
    {
      alert = "DHCPUnknownLease";
      expr = "homelab_dhcp_unknown_leases > 0";
      labels.notify = "ops";
      annotations.summary = "{{ $value }} DHCP lease(s) on {{ $labels.interface }} at {{ $labels.instance }} held by hardware the inventory does not name there.";
    }
    # Traffic from a management LAN host neither admitted nor in
    # mgmt_known, dropped or only counted per homelab.mgmtLockdown.enforce.
    # The journal's "nft mgmt unknown" lines name the MAC.
    {
      alert = "MgmtUnknownHost";
      expr = ''increase(nftables_counter_packets_total{name="mgmt_unknown"}[10m]) > 0'';
      labels.notify = "ops";
      annotations.summary = "{{ $labels.instance }} saw traffic on the management LAN from hardware the inventory does not name there.";
    }
    # Every HTTPS probe target's certificate, whoever issues it: Tailscale
    # renews its Services certificates itself, and the acme module
    # renews the ones this flake issues (the router's dn42 peering page,
    # from Let's Encrypt over DNS-01) from 30 days out, retrying daily.
    # Both are 90-day certificates, so anything under 14 days means
    # renewal has been failing for over two weeks, which nothing else
    # reports. The probes are discovered with the certificates; see
    # prometheus.nix.
    {
      alert = "TLSCertificateExpiringSoon";
      expr = "probe_ssl_earliest_cert_expiry - time() < 14 * 86400";
      for = "1h";
      annotations.summary = "TLS certificate for {{ $labels.instance }} expires in under 14 days.";
    }
    # The router's two uplinks fail in different ways and neither was
    # visible before this rule.
    #
    # IPv4 is routed by metric: the uplinks carry static and DHCP
    # metrics set in the router's networking.nix, so losing the
    # preferred one silently moves every IPv4 flow to the other. It
    # keeps working, on a different path, and nothing says so.
    #
    # IPv6 is not redundant at all: only one uplink offers it, and it
    # carries the DHCPv6-PD delegation every LAN prefix is carved from.
    # Losing that link eventually surfaces as
    # CoreRADMonitorDefaultRouteWANExpiring, but only once the upstream
    # RA's route lifetime runs down to its last two hours. Carrier says
    # it in two minutes.
    #
    # What carrier cannot see is an uplink that is up but black-holing:
    # the static route stays installed, so there is no failover and no
    # carrier change. The ICMP probes to both public anchors cover that
    # case through BlackboxPacketLoss and BlackboxServiceDown, which is
    # why this rule does not try to.
    {
      alert = "WANLinkDown";
      expr = "node_network_carrier{instance=~${routerInstances},device=~${raw "wan[0-9]+"}} == 0";
      for = "2m";
      annotations.summary = "WAN uplink {{ $labels.device }} on {{ $labels.instance }} has lost carrier.";
    }
  ];
}
