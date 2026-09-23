# Prometheus rules: alerting rules sorted alphabetically by alert name, then
# recording rules. Host and job specifics come from the inventory in
# prometheus.nix rather than being hardcoded here.
{
  lib,
  # Every anycast service address and the site expected to answer it, as
  # { service, address, site }; see nixos/modules/anycast.nix.
  anycastServices,
  # How many routers run the IGP, and so how many LSPs each link-state
  # database should hold.
  isisRouterCount,
  # Builds a Grafana Explore link for a LogQL query, for alerts which fire on
  # what Loki's ruler records; see nixos/servnerr-4/explore-url.nix.
  exploreURL,
  # Hosts which don't run 24/7 and should never raise down alerts.
  excludedHosts,
  # Jobs whose targets are too unreliable to raise down alerts, or whose
  # down state other rules already report on better thresholds.
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

  # The iBGP sessions between the dn42 nodes' loopbacks (ibgp_<machine>,
  # see modules/dn42.nix): a site without peers of its own exports nothing
  # over them, so the peering site's end is Established and empty by
  # design. Session state still alerts; an empty import does not.
  interconnectProtocols = raw "ibgp_.*";
  internalInterfaces = raw "dn42i-.*";

  # The IS-IS sample, matched on its name so the textfile directory's path
  # is not repeated here; node_exporter labels each file by its full path.
  isisTextfile = raw ".*/isis\\.prom";
  notifyTextfile = raw ".*/update-notify\\.prom";

  excludedInstances = hostsRegex excludedHosts;
  routerInstances = hostsRegex routers;
  excludedJobsRegex = raw (anyOf excludedJobs);

  # The smartctl exporter keys every metric by kernel device name, which is
  # not stable across reboots, and carries the model and serial only on its
  # smartctl_device info metric. Joining those in names the physical drive in
  # a notification and gives a silence a matcher that survives a renumber.
  # Both come from one scrape, so the info series is never missing alone.
  withDrive =
    expr: "(${expr}) * on (instance, device) group_left(model_name, serial_number) smartctl_device";

  # The same join for a metric recorded by Loki's ruler, which labels by host
  # rather than instance. The host is derived from the instance label so that
  # no domain or exporter port is repeated here.
  withDriveByHost =
    expr:
    "(${expr}) * on (host, device) group_left(model_name, serial_number) "
    + ''label_replace(smartctl_device, "host", "$1", "instance", ${raw "([^.:]+).*"})'';

  # One rule per site and service address. A single node withdrawing its
  # address is the design working; a site where nothing holds it is not.
  # absent() because a count has no series at zero, guarded on the site
  # answering at all so a dead exporter is not read as a withdrawal.
  anycastRules = map (s: {
    alert = "AnycastAddressMissing";
    expr = ''
      absent(node_network_address_info{device="anycast", address="${s.address}", site="${s.site}"})
      and on () count(up{job="node", site="${s.site}"} == 1) > 0
    '';
    for = "10m";
    annotations.summary = "No node at site ${s.site} holds ${s.address}, so nothing there answers ${s.service} and every request from its clients crosses the fabric.";
  }) anycastServices;
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
      ]
      ++ anycastRules
      ++ [
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
        # BFD is opt-in per dn42 peer, and only on a node whose IGP does
        # not hold the port. The bird exporter reports BFD as
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
          expr = ''bird_protocol_prefix_import_count{proto="BGP",name!~${internalProtocols},name!~${interconnectProtocols}} == 0 and on (instance, name, ip_version) bird_protocol_up{proto="BGP"} == 1'';
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
        #
        # Aggregated rather than matched raw: the exporter puts the protocol
        # state in a label, reason text and all, so a peer bouncing between
        # `Idle BGP Error: Hold timer expired` and `Connect` is a new series
        # each hop and the `for` timer restarts. Collapsing to one series per
        # peer and family is safe here because a BGP protocol reports up=1
        # only while Established -- which is not true of RPKI below, hence
        # the different shape there.
        {
          alert = "BIRDBGPSessionDown";
          expr = ''max by (instance, name, ip_version) (bird_protocol_up{proto="BGP",name!~${internalProtocols}}) == 0'';
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
        # Multiple RTR servers feed the same ROA tables, so one down is
        # redundancy doing its job rather than an outage, and the tables
        # hold their data for the two hour expire window. That leaves
        # plenty of room to wait out a refresh or retry cycle before
        # alerting; what this catches ahead of an empty table is the rest
        # of the feeds going the same way. rpki_sess_flap is in here too
        # and matters less: its tables fail open, so losing it suppresses
        # nothing rather than rejecting everything.
        #
        # Not `bird_protocol_up == 0`: the exporter puts the protocol state
        # in a label, so a session cycling Transport-Error -> Connecting ->
        # Sync-Start is a different series each hop and the `for` timer
        # restarts every retry, never reaching 30m. Sync-Start reports up=1
        # besides. Ask instead for a session with no Established series,
        # which is one series per session and holds across the flapping.
        {
          alert = "BIRDRPKISessionDown";
          expr = ''count by (instance, name) (bird_protocol_up{proto="RPKI"}) unless on (instance, name) bird_protocol_up{proto="RPKI", state="Established"}'';
          for = "30m";
          annotations.summary = "RPKI validator session {{ $labels.name }} on {{ $labels.instance }} is not Established.";
        }
        # FRR runs the IGP on the site interconnects, beside bird rather
        # than instead of it. This is a liveness check on the daemon and
        # nothing more: the status collector asks zebra for `show version`,
        # so isisd can be dead with frr_status_up still 1.
        #
        # frr_collector_up is in here because a collector which cannot read
        # FRR's sockets -- the exporter dropping out of the frrvty group is
        # the way that happens -- still serves a 200, so the scrape stays
        # up and every metric it should have produced is simply missing.
        #
        {
          alert = "FRRDown";
          expr = ''up{job="frr"} == 0 or frr_status_up == 0 or frr_collector_up == 0'';
          for = "10m";
          annotations.summary = "FRR on {{ $labels.instance }} is down or a collector is failing, so the IGP is unmonitored.";
        }
        # isisd removes a circuit's BFD session with its adjacency, so a
        # dead circuit's frr_bfd_peer_state vanishes rather than reading 0
        # and ISISAdjacencyDown covers it. This is the other case: an
        # adjacency up on hellos alone, with no BFD session behind it. The
        # adjacency sample labels the circuit interface, the exporter
        # iface; joined on site, since the two exporters have different
        # instance ports.
        {
          alert = "ISISBFDSessionMissing";
          expr = ''homelab_isis_adjacency_up == 1 unless on (site, interface) label_replace(frr_bfd_peer_state == 1, "interface", "$1", "iface", "(.*)")'';
          for = "5m";
          annotations.summary = "IS-IS adjacency on {{ $labels.interface }} ({{ $labels.instance }}) is up without an up BFD session, so a dead circuit would take the 30 s hello holding time to notice.";
        }
        # The adjacency itself, from the textfile exporter in
        # nixos/modules/isis-metrics.nix. Its series are rendered from the
        # circuits each router is configured with, so an adjacency which
        # drops reads 0 instead of disappearing and `== 0` is enough.
        #
        # The sample is written once a minute and a circuit crosses the
        # internet, so this waits several of them: a hello exchange missed
        # once is not worth a page, and an adjacency which does not come
        # back is what this is for.
        {
          alert = "ISISAdjacencyDown";
          expr = "homelab_isis_adjacency_up == 0";
          for = "5m";
          annotations.summary = "IS-IS adjacency on {{ $labels.interface }} to site {{ $labels.far }} is down, so {{ $labels.instance }} has no IGP path there.";
        }
        # The adjacency gauge above is only as true as the file it comes
        # from. node_exporter keeps serving the last sample written, so a
        # collector which stops running leaves the adjacency reading what it
        # read when it died, and a circuit which drops after that is never
        # reported. The sample is written every minute.
        # One LSP per router, while every level-2 circuit is point to
        # point and no router overflows lspMtu: a broadcast circuit adds a
        # pseudonode LSP per level, an overflow adds fragments. Short of
        # the count a router is gone, which ISISAdjacencyDown misses when a
        # site is reachable by neither plane and the rest agree among
        # themselves.
        {
          alert = "ISISLSDBUnexpected";
          expr = ''homelab_isis_lsps{level="2"} != ${toString isisRouterCount}'';
          for = "10m";
          annotations.summary = "{{ $labels.instance }} holds {{ $value }} level-2 LSPs where the area has ${toString isisRouterCount} routers, so its database is missing one or carrying one nobody expects.";
        }
        {
          alert = "ISISMetricsStale";
          expr = "time() - node_textfile_mtime_seconds{file=~${isisTextfile}} > 300";
          annotations.summary = "The IS-IS sample on {{ $labels.instance }} is {{ $value | humanizeDuration }} old, so its adjacency state is not to be trusted.";
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
        # A LAN client's query to the anycast resolver, probed from a segment
        # no holder sits on (nixos/modules/anycast-probe.nix). AnycastAddressMissing
        # watches whether a site holds the address; this watches whether an
        # answer comes back, which the 2026-09-21 withdrawal exercise showed
        # can fail while every holder is healthy. Two minutes rather than
        # BlackboxServiceDown's five: every client at the site is without
        # names while it fires.
        # The same fault seen from where it happens: a holder's reply sourced
        # from an anycast address arriving on a LAN the router does not route
        # that address to, which its anti-spoof check drops (the router's
        # nftables.nix counts these apart from other spoofed sources). One
        # is a client without an answer, so no hold beyond the scrape.
        {
          alert = "AnycastReplyDropped";
          expr = ''rate(nftables_counter_packets_total{name="anycast_reply_drop"}[2m]) > 0'';
          for = "1m";
          annotations.summary = "{{ $labels.instance }} is dropping replies sourced from an anycast address that arrive on a LAN it routes that address away from, so a holder's answers are not reaching clients.";
        }
        {
          alert = "AnycastResolverUnreachable";
          expr = ''probe_success{job="blackbox_dns_anycast"} == 0'';
          for = "2m";
          annotations.summary = "A LAN client's {{ $labels.family }} query to the anycast resolver {{ $labels.instance }} goes unanswered, so every client following that address has no names.";
        }
        {
          alert = "BlackboxServiceDown";
          expr = "probe_success{instance!~${excludedInstances},job!~${excludedJobsRegex}} == 0";
          for = "5m";
          annotations.summary = "{{ $labels.instance }} of job {{ $labels.job }} has been down for more than 5 minutes.";
        }
        # As with BIRDExporterFailing: a failed command socket query drops the
        # chrony metrics rather than zeroing them, so every rule below goes
        # quiet exactly when this one fires.
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
        # Some dn42 networks drop a session whose latency exceeds 100ms, so
        # that is the permissible round trip to any peer, and 80ms leaves
        # margin to act. The metric is the ICMP round trip to a peer's
        # link-local address across its own tunnel, probed by the router's
        # dn42_peer_exporter (see its dn42.nix). A 15 minute average rather
        # than a `for`, since a path hovering around the line would keep
        # resetting a timer. A failed probe publishes no round trip at all,
        # so it neither lowers the average nor fires this; a dead tunnel is
        # the WireGuard and BIRD rules' to report. External peers only: the
        # exporter's peers are the router's dn42 peer set, which has no
        # dn42i-* entries.
        {
          alert = "DN42PeerLatencyHigh";
          expr = "avg_over_time(dn42_peer_rtt_seconds[15m]) > 0.080";
          annotations.summary = "dn42 peer {{ $labels.peer }} ({{ $labels.instance }}) has averaged a {{ $value | humanizeDuration }} round trip over 15 minutes, above the 80ms warning line for a 100ms limit.";
        }
        # A tunnel that carries small packets but drops full-size ones is
        # the quiet dn42 failure: the session stays up while large updates
        # and traffic blackhole. After each answered probe the exporter
        # sends an echo filling the tunnel's MTU, whose reply is the same
        # size, so requiring the peer to be up isolates packet size from
        # plain reachability, and 15 minutes rules out a single lost reply.
        {
          alert = "DN42PeerMTUBlackhole";
          expr = "dn42_peer_up == 1 and dn42_peer_mtu_up == 0";
          for = "15m";
          annotations.summary = "dn42 peer {{ $labels.peer }} ({{ $labels.instance }}) answers small echo requests but not ones filling the tunnel's MTU, so the path drops full-size packets.";
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
        # shipped nothing at all, even though its Alloy may still report up.
        # The lookback spans several windows because a host whose only logs
        # are an hourly timer aliases in and out of the metric on its own.
        # Every host firing at once means the ruler or its remote write path
        # is broken, not the shippers.
        {
          alert = "LokiHostLogsStalled";
          expr = lib.concatMapStringsSep " or " (
            host: ''absent_over_time(host:log_lines:count1h{host="${host}"}[6h])''
          ) logHosts;
          for = "30m";
          annotations.summary = "{{ $labels.host }} has shipped no logs to Loki for over six hours.";
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
        # The case NixOSSystemUnpersisted cannot see: a switch from a tree
        # with uncommitted changes persists to the profile like any other,
        # and the machine then runs configuration that exists nowhere but
        # that working tree. The nightly upgrade rebuilds origin/main at
        # about 04:00 and replaces it without a word, which is how a change
        # once ran for half a day and then vanished. The metric comes from
        # the revision baked into each system; see
        # nixos/modules/system-metrics.nix.
        #
        # The wait is the tradeoff. A test or switch from a dirty tree is how
        # every change is tried during a working session and must not page,
        # but a dirty build still running twelve hours later has outlived
        # the session that made it and is heading for the nightly. A full
        # day would be quieter still and would almost never fire, since the
        # nightly resets the metric first; twelve hours leaves time to commit
        # and merge, or to expect the revert, before it does. Whether the
        # running commit matches origin/main is a question Prometheus cannot
        # answer, so this stops at dirtiness.
        {
          alert = "NixOSSystemDirty";
          expr = "nixos_system_dirty == 1";
          for = "12h";
          annotations.summary = "{{ $labels.instance }} has run a system built from uncommitted changes for over 12 hours; the nightly upgrade will replace it with main.";
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
        # update-notify spools each announcement and returns, so a deploy no
        # longer waits on a chat webhook (see nixos/modules/common.nix). That
        # trades a slow deploy for a silent one unless something watches the
        # spool, since nothing else notices an announcement never delivered.
        # The drain rewrites its metrics file on every run, empty queue
        # included, so the file's own age catches a drainer that stopped
        # running and left the gauge frozen at its last value.
        {
          alert = "DeployNotifyUndelivered";
          expr = ''
            homelab_deploy_notify_oldest_seconds > 1800
            or time() - node_textfile_mtime_seconds{file=~${notifyTextfile}} > 1800
          '';
          for = "5m";
          annotations.summary = "{{ $labels.instance }} has not delivered a system update announcement to the ops channel in over 30 minutes.";
        }
        # NVMe wear estimate: 100% is the rated endurance, and the value may
        # keep counting past it. 80% leaves months of lead time at current
        # write rates.
        {
          alert = "NVMeWearHigh";
          expr = withDrive "smartctl_device_percentage_used >= 80";
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
          expr = withDrive "smartctl_device_critical_warning > 0";
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
          expr = withDrive "increase(smartctl_device_error_log_count[1d]) > 0 or increase(smartctl_device_media_errors[1d]) > 0";
          annotations.summary = "Disk {{ $labels.device }} on {{ $labels.instance }} logged new SMART errors in the last day.";
        }
        # Fires from a log line rather than a metric, recorded into Prometheus
        # by Loki's ruler (see nixos/servnerr-4/loki.nix) so that the drive's
        # serial can be joined in here. A broken ruler or remote write path
        # silences this rule, which is what LokiHostLogsStalled reports on.
        {
          alert = "SMARTSelfTestFailed";
          expr = withDriveByHost "host_device:smartd_selftest_errors:count15m > 0";
          annotations = {
            summary = "Disk {{ $labels.device }} ({{ $labels.model_name }}, {{ $labels.serial_number }}) on {{ $labels.host }} failed a SMART self-test.";
            logs_url = exploreURL ''{host="__host__", job="systemd-journal", unit="smartd.service"}'';
          };
        }
        {
          alert = "SMARTStatusFailed";
          expr = withDrive "smartctl_device_smart_status == 0";
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
        # The other half of SystemdUnitFailed, which sees only the current
        # state: a unit that crashes and comes back is invisible to it.
        #
        # NRestarts counts automatic restarts since the unit was last
        # started, so a deploy or any manual restart sets it back to zero.
        # That is why the count is read from the counter itself rather than
        # from increase() over it: increase() reads each of those resets as a
        # counter wrap and adds the pre-reset value, manufacturing restarts
        # that never happened on a day with several deploys. It fired on a
        # getty that had restarted once on 2026-09-21 for exactly that
        # reason, and extrapolation carried the total past a whole number.
        #
        # One crash overnight is not worth a notification; a third means it
        # is not recovering. The second term is what says "still": without it
        # a unit that looped once and settled keeps alerting until something
        # restarts it.
        {
          alert = "SystemdUnitRestarting";
          expr = ''
            node_systemd_service_restart_total > 2
            and increase(node_systemd_service_restart_total[30m]) > 0
          '';
          for = "10m";
          annotations.summary = "Unit {{ $labels.name }} on {{ $labels.instance }} has been restarted {{ $value | humanize }} times by systemd since it was last started.";
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
        # As with BIRDExporterFailing: a failed scrape drops the handshake
        # metrics rather than zeroing them, so the rule below goes quiet
        # exactly when the exporter does. Overlapping PrometheusInstanceDown
        # is the point, naming the consequence.
        {
          alert = "WireGuardExporterDown";
          expr = ''up{job="wireguard"} == 0'';
          for = "5m";
          annotations.summary = "The WireGuard exporter on {{ $labels.instance }} is down, so its tunnel handshakes are unmonitored.";
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
        #
        # The interconnect carriers (iclw-) qualify on the same reasoning:
        # the IGP's hellos cross them every few seconds, so a quiet carrier
        # is a dead one there too, and both ends of a carrier run the
        # exporter, so a circuit between two edges is measured as well.
        {
          alert = "WireGuardPeerHandshakeStale";
          expr = "wireguard_latest_handshake_delay_seconds{interface=~${raw "(dn42e|iclw)-.*"}} > 180";
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
    # Recording rules, named level:metric:operations like Loki's
    # host:log_lines:count1h; see loki.nix.
    {
      name = "recording";
      rules = [
        # BGP session state changes per hour, as a series to graph and alert
        # on rather than a query to remember. BIRDBGPSessionDown needs ten
        # straight minutes down, so a session bouncing every few minutes
        # never trips it and only shows up here.
        #
        # The subquery is load-bearing: the exporter puts a state label
        # (Established, Active, Idle ... Error: ...) on a BGP protocol's
        # IPv4 channel, so each state change there starts a new series, each
        # of them constant for its life, and changes() over the raw metric
        # counts nothing for IPv4. Collapsing to one series per session and
        # channel first, at scrape resolution, is what makes the count
        # right. Not filtered to external peers: the internal dn42i_*
        # sessions are expected to bounce, and it is the alerts, not the
        # record, that leave them out.
        {
          record = "instance_name_ip_version:bird_protocol_up:changes1h";
          expr = ''changes((max by (instance, name, ip_version) (bird_protocol_up{proto="BGP"}))[1h:15s])'';
        }
      ];
    }
  ];
}
