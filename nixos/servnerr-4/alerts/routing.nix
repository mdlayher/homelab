# Routing: BGP, BFD and RPKI in BIRD, the RTR cache, IS-IS in FRR, the dn42
# peers and their WireGuard tunnels, and the anycast service addresses.
{
  lib,
  isisRouterCounts,
  exploreURL,
  routers,
  raw,
  internalProtocols,
  interconnectProtocols,
  internalInterfaces,
  isisTextfile,
  anycastRules,
  ...
}:

{
  name = "routing";
  rules = anycastRules ++ [
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
    # rtrtr resets this age only when the RTR cache's ROA set changes
    # or a fetch starts failing, and the registry can go several days
    # without a change, so it is checked against the 7 days burble's
    # export declares itself valid for. The cache keeps serving its last
    # set meanwhile, and every BIRD node stays Established on it.
    {
      alert = "RTRCacheStale";
      expr = "rtrtr_since_last_update_seconds > 7*24*60*60";
      annotations.summary = "The RTR cache's ROA set on {{ $labels.instance }} has not changed in 7 days.";
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
    # A circuit whose path keeps losing BFD for a moment. The adjacency
    # returns within a second, too fast for ISISAdjacencyDown. Drops
    # within five minutes of FRR or networkd starting on any IGP node
    # are left out: a deploy drops the far ends' adjacencies too. The
    # drops are recorded by Loki's ruler (see nixos/servnerr-4/loki.nix);
    # each minute step reads only the samples in its own minute, so no
    # drop is counted twice.
    #
    # The alert counts hours with a drop, not drops, so a burst of path
    # loss counts once and only drops recurring across the day fire it.
    # It fires only while the latest drop is under an hour old, so a
    # path that settles resolves after that hour rather than once the
    # day has aged out.
    (
      let
        hourlyDrops = ''
          sum by (host, circuit) (sum_over_time((
            sum_over_time(host_circuit:isis_bfd_drops:count1m[1m])
              unless on () (min(time() - node_systemd_unit_start_time_seconds{name=~"frr.service|systemd-networkd.service"}) < 300)
          )[1h:1m])) > 0
        '';
      in
      {
        alert = "ISISAdjacencyFlapping";
        expr = ''
          count_over_time((${hourlyDrops})[1d:1h]) >= 3
            and on (host, circuit) (${hourlyDrops})
        '';
        annotations = {
          summary = "IS-IS on {{ $labels.circuit }} ({{ $labels.host }}) lost BFD in {{ $value }} separate hours of a day outside deploys; check the path under that plane.";
          logs_url = exploreURL ''{host="__host__", job="systemd-journal", unit="frr.service"} |= `bfd session went down`'';
        };
      }
    )
    # One LSP per router at each level, while every circuit is point to
    # point and no router overflows lspMtu: a broadcast circuit adds a
    # pseudonode LSP per level, an overflow adds fragments. Short of
    # the count a router is gone, which ISISAdjacencyDown misses when a
    # site is reachable by neither plane and the rest agree among
    # themselves. A level-1 database holds its own site's routers.
    {
      alert = "ISISLSDBUnexpected";
      expr = lib.concatStringsSep " or " (
        [ ''homelab_isis_lsps{level="2"} != ${toString isisRouterCounts.level2}'' ]
        ++ lib.mapAttrsToList (
          site: n: ''homelab_isis_lsps{level="1",site="${site}"} != ${toString n}''
        ) isisRouterCounts.level1
      );
      for = "10m";
      annotations.summary = "{{ $labels.instance }} holds {{ $value }} level-{{ $labels.level }} LSPs, more or fewer than the routers at that level, so its database is missing one or carrying one nobody expects.";
    }
    # The adjacency gauge is only as true as the file it comes from.
    # node_exporter keeps serving the last sample written, so a
    # collector which stops running leaves the adjacency reading what it
    # read when it died, and a circuit which drops after that is never
    # reported. The sample is written every minute.
    #
    # The wait covers reboots: a rebooted machine keeps its old sample
    # on disk until the collector's first run, and a restarted
    # Prometheus evaluates samples from before it went down until the
    # first scrapes land.
    {
      alert = "ISISMetricsStale";
      expr = "time() - node_textfile_mtime_seconds{file=~${isisTextfile}} > 300";
      for = "10m";
      annotations.summary = "The IS-IS sample on {{ $labels.instance }} is {{ $value | humanizeDuration }} old, so its adjacency state is not to be trusted.";
    }
    # A holder's reply sourced from an anycast address arriving on a LAN
    # the router does not route that address to, which its anti-spoof
    # check drops (the router's nftables.nix counts these apart from
    # other spoofed sources). One is a client without an answer, so no
    # hold beyond the scrape.
    {
      alert = "AnycastReplyDropped";
      expr = ''rate(nftables_counter_packets_total{name="anycast_reply_drop"}[2m]) > 0'';
      for = "1m";
      annotations.summary = "{{ $labels.instance }} is dropping replies sourced from an anycast address that arrive on a LAN it routes that address away from, so a holder's answers are not reaching clients.";
    }
    # A LAN client's query to the anycast resolver, probed from a segment
    # no holder sits on (nixos/modules/anycast-probe.nix). AnycastAddressMissing
    # watches whether a site holds the address; this watches whether an
    # answer comes back, which the 2026-09-21 withdrawal exercise showed
    # can fail while every holder is healthy. Two minutes rather than
    # BlackboxServiceDown's five: every client at the site is without
    # names while it fires.
    {
      alert = "AnycastResolverUnreachable";
      expr = ''probe_success{job="blackbox_dns_anycast"} == 0'';
      for = "2m";
      annotations.summary = "A LAN client's {{ $labels.family }} query to the anycast resolver {{ $labels.instance }} goes unanswered, so every client following that address has no names.";
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
  ];
}
