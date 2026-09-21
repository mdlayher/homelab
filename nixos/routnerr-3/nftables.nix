{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:

let
  inventory = config.homelab.inventory;

  # Interface groups. Restricted LANs may only reach the internet and a few
  # router services; trusted LANs may reach everything. A restricted LAN the
  # inventory marks debug may also originate ICMP anywhere the rules would
  # otherwise drop it, so that segment can probe the network it studies.
  wans = [
    "wan0"
    "wan1"
  ];
  # Drawn from the inventory's own classification rather than listed again
  # here: two registries of which LAN is trusted can disagree, and this is
  # the one that enforces it. The tailnet is trusted alongside them and has
  # no inventory entry, being no LAN.
  lansWhere = pred: lib.filter pred (lib.attrValues inventory.interfaces);
  trusted = lansWhere (ifi: ifi.trusted) ++ [ { name = "ts0"; } ];
  restricted = lansWhere (ifi: !ifi.trusted);
  debugLans = lansWhere (ifi: ifi.debug);

  # Produces an nftables set of interface names.
  ifnames = ifis: "{ ${lib.concatMapStringsSep ", " (ifi: ifi.name or ifi) ifis} }";

  # Different tailscaled ports for different devices to avoid messing with
  # poking nftables firewall holes with miniupnpd or similar. The router
  # keeps Tailscale's default, which is also the port peers probe blindly
  # for any address they have not learned a port for; the forwarded hosts
  # take the ones after it.
  tailscale = {
    router = 41641;
    # Peer relay: tailnet pairs which cannot connect directly - notably a
    # phone on cellular reaching hosts with no WAN port forward - relay
    # through this machine instead of a distant DERP server. Payloads are
    # WireGuard, encrypted end to end; usage is gated by a tailnet policy
    # grant.
    relay = 41462;
    forwards = with inventory.hosts; [
      {
        host = nerr-4;
        port = 41642;
      }
      {
        host = psframework;
        port = 41643;
      }
    ];
  };

  # Addresses are secrets from the inventory, so rules reference named sets
  # which are populated at activation time from this rendered file. Empty sets
  # fail closed.
  elements =
    let
      routers = ifi: lib.concatMapStringsSep ", " (addr: "${ifi.name} . ${addr}");
      forwards = f: lib.concatMapStringsSep ", " f tailscale.forwards;
    in
    ''
      add element inet filter router_v4 { ${
        lib.concatMapStringsSep ", " (ifi: routers ifi [ ifi.ipv4 ]) restricted
      } }
      add element inet filter router_v6 { ${
        lib.concatMapStringsSep ", " (
          ifi:
          routers ifi [
            ifi.lla
            ifi.ula
          ]
        ) restricted
      } }
      add element inet filter tailscale_v4 { ${forwards (ts: "${ts.host.ipv4} . ${toString ts.port}")} }
      add element inet filter tailscale_v6 { ${forwards (ts: "${ts.host.gua} . ${toString ts.port}")} }
      ${lib.optionalString (icl && iclServices != [ ])
        "add element inet filter icl_services_v6 { ${
          lib.concatMapStringsSep ", " (s: "${s.host.ula} . ${toString s.port}") iclServices
        } }"
      }
      add element ip nat tailscale_dnat { ${forwards (ts: "${toString ts.port} : ${ts.host.ipv4}")} }
    '';

  nft = "${pkgs.nftables}/bin/nft";
  elementsFile = config.sops.templates."nftables-inventory.conf".path;

  # dn42 peering (see dn42.nix): interfaces are dn42e-<peer> for the tunnels
  # to other networks and dn42i-<name> for our own dn42-addressed VLANs.
  # Both are matched by wildcard so the ruleset does not change per peer or
  # per VLAN; only the per-peer WireGuard listen ports on the WANs do.
  #
  # The two prefixes are never covered by one dn42-* wildcard, which would
  # match either and merge the trust classes. External is somebody else's
  # network; internal is ours.
  dn42 = config.homelab.dn42;
  dn42Ports = lib.mapAttrsToList (_: peer: toString peer.port) dn42.peers;

  # Site interconnects (see modules/interconnect.nix). Unlike every other
  # interface here these carry two trust classes on one wire -- our own ULA
  # and dn42 registry space -- so the rules below classify them by address
  # rather than by name, which is what the dn42e-/dn42i- split relies on.
  interconnect = config.homelab.interconnect;
  iclPorts = map toString (
    lib.filter (p: p != null) (lib.mapAttrsToList (_: link: link.port) interconnect.links)
  );
  icl = interconnect.links != { };

  # A link with no WireGuard carrier is a bare GRETAP, so its outer packets
  # are raw GRE on whichever interface reaches the far end rather than UDP
  # to a port on the WAN. Only a same-site link is built that way.
  iclBare = lib.any (link: link.carrier == null) (lib.attrValues interconnect.links);

  # Services at this site a far site initiates toward, by the host holding
  # the role and the port that host's own configuration listens on: every
  # edge's Alloy pushes its journal to Loki on each server role holder, the
  # way modules/alloy.nix names them. The addresses are inventory secrets,
  # so they reach the ruleset through the rendered set below.
  iclServices = map (server: {
    host = inventory.hosts.${server};
    port =
      inputs.self.nixosConfigurations.${server}.config.services.loki.configuration.server.http_listen_port;
  }) inventory.roles.server;

  # ns1 for our dn42 domain: CoreDNS serves only the authoritative zones on
  # the router's dn42 addresses (see coredns.nix), never recursion, so this
  # opens no resolver to dn42. Repeated per chain, as both sides may ask.
  dn42Dns = side: ''
    ip daddr ${dn42.addr4} meta l4proto { tcp, udp } th dport $dns counter accept comment "router dn42 ${side} DNS"
    ip6 daddr ${dn42.addr6} meta l4proto { tcp, udp } th dport $dns counter accept comment "router dn42 ${side} DNS"
  '';

  # LAN interface names for per-LAN WAN accounting, including the tailnet
  # interface so exit node traffic is counted.
  lans = map (ifi: ifi.name or ifi) (trusted ++ restricted);

  # Address families for the per-host WAN accounting sets. Keys concatenate
  # the LAN interface with the host address, so a host appearing on two LANs
  # is accounted separately per interface.
  protos = [
    {
      v = "4";
      type = "ifname . ipv4_addr";
      outKey = "iifname . ip saddr";
      inKey = "oifname . ip daddr";
    }
    {
      v = "6";
      type = "ifname . ipv6_addr";
      outKey = "iifname . ip6 saddr";
      inKey = "oifname . ip6 daddr";
    }
  ];
in
{
  # The exporter for the named counters below; see the module.
  imports = [ ../modules/nftables-exporter.nix ];

  sops.templates."nftables-inventory.conf" = {
    content = elements;
    restartUnits = [ "nftables-inventory.service" ];
  };

  # Load inventory set elements after the ruleset is (re)loaded, since loading
  # the ruleset flushes all sets.
  systemd.services.nftables-inventory = {
    description = "nftables inventory set elements";
    after = [ "nftables.service" ];
    requires = [ "nftables.service" ];
    partOf = [ "nftables.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${nft} -f ${elementsFile}";
    };
  };
  systemd.services.nftables.serviceConfig.ExecReload = lib.mkAfter [ "${nft} -f ${elementsFile}" ];

  # Advertise this machine as a tailnet peer relay on the port opened above.
  services.tailscale.extraSetFlags = [ "--relay-server-port=${toString tailscale.relay}" ];

  networking.nftables = {
    enable = true;
    ruleset = ''
      define wans = ${ifnames wans}
      define trusted_lans = ${ifnames trusted}
      define restricted_lans = ${ifnames restricted}
      ${lib.optionalString (debugLans != [ ]) "define debug_lans = ${ifnames debugLans}"}
      define all_lans = ${ifnames (trusted ++ restricted)}
      define physical_lans = ${ifnames (lib.filter (ifi: ifi ? vlan) (trusted ++ restricted))}

      # Our own space, for classifying interconnect traffic: both come from
      # the inventory, which explains why the v4 side is a whole /16 and
      # what it must stay disjoint from.
      define lab6 = ${inventory.labPrefix6}
      define carrier6 = ${inventory.carrierPrefix}
      define site4 = { ${inventory.privatePrefix}, ${inventory.legacyPrefix} }
      define site6 = ${inventory.ulaPrefix}
      define loopback6 = ${inventory.loopbacks.${config.networking.hostName}.addr6}

      # The service addresses this router answers at along with every other
      # node holding them (see modules/anycast.nix). Plain inventory data,
      # so they are written here rather than into a set rendered from the
      # secrets.
      define anycast_dns = ${inventory.anycast6.dns}
      define anycast_ntp = ${inventory.anycast6.ntp}
      define anycast4_dns = ${inventory.anycast4.dns}
      define anycast4_ntp = ${inventory.anycast4.ntp}

      define dns = 53
      define ntp = 123
      define http = 80
      define https = 443
      define bgp = 179
      define bfd_control = 3784
      define peerfinder = ${toString dn42.peerfinder.port}
      define dhcp4_server = 67
      define dhcp4_client = 68
      define dhcp6_client = 546
      define dhcp6_server = 547
      define mdns = 5353
      define tailscale_router = ${toString tailscale.router}
      define tailscale_relay = ${toString tailscale.relay}

      table inet filter {
        # Named counters for notable drops and rejects, readable as one list
        # with 'nft list counters' and exported to Prometheus; see
        # nftables-counters. Multiple rules may share one counter.
        counter spoofed_drop {}
        counter anycast_reply_drop {}
        counter input_reject {}
        counter wan_input_drop {}
        counter restricted_crossvlan_drop {}
        counter restricted_input_drop {}
        counter restricted_forward_drop {}
        counter forward_reject {}
        counter wan_forward_drop {}
        counter dn42_input_drop {}
        counter dn42_forward_drop {}
        ${lib.optionalString icl ''
          counter icl_input_drop {}
          counter icl_forward_drop {}
        ''}
        counter dn42_inbound_drop {}
        counter blackhole_drop {}

        # Router addresses on restricted LANs: the only local destinations
        # those LANs may talk to.
        set router_v4 {
          type ifname . ipv4_addr
        }
        set router_v6 {
          type ifname . ipv6_addr
        }

        # LAN hosts which accept inbound Tailscale traffic from the WAN.
        set tailscale_v4 {
          type ipv4_addr . inet_service
        }
        set tailscale_v6 {
          type ipv6_addr . inet_service
        }

        ${lib.optionalString icl ''
          # Services at this site a far site initiates toward, by host
          # address and port; see forward_icl.
          set icl_services_v6 {
            type ipv6_addr . inet_service
          }
        ''}

        # Drop packets from physical LANs whose source address does not belong
        # on the interface they arrived on. The kernel exempts DHCP/DAD
        # (unspecified source to broadcast/multicast).
        chain prerouting {
          type filter hook prerouting priority raw
          policy accept

          iifname $physical_lans fib saddr . iif oif missing limit rate 10/minute burst 20 packets log prefix "nft spoofed drop: "
          # A holder's reply sourced from an anycast address, arriving on a
          # LAN this router routes that address away from: dropped like any
          # spoofed source, counted apart so the failure has an alert
          # (AnycastReplyDropped). Seen on 2026-09-21 when the server
          # answered in the router's place and replied over mgmt0.
          iifname $physical_lans ip6 saddr { $anycast_dns, $anycast_ntp } fib saddr . iif oif missing counter name anycast_reply_drop drop comment "anycast reply on the wrong LAN"
          iifname $physical_lans ip saddr { $anycast4_dns, $anycast4_ntp } fib saddr . iif oif missing counter name anycast_reply_drop drop comment "anycast reply on the wrong LAN"
          iifname $physical_lans fib saddr . iif oif missing counter name spoofed_drop drop comment "spoofed source"

          # Anything the routing table would discard, counted here because
          # a blackholed packet is dropped at the routing decision and
          # never reaches the forward hook. The discard prefix on lo is
          # one such route (see modules/interconnect.nix); a prefix
          # null-routed by hand or by announcement is another.
          fib daddr type blackhole counter name blackhole_drop drop comment "blackholed destination"
        }

        # ICMP allowed from LANs: pings, errors, and neighbor discovery.
        chain icmp_lan {
          ip6 nexthdr icmpv6 icmpv6 type {
            echo-request,
            echo-reply,
            destination-unreachable,
            packet-too-big,
            time-exceeded,
            parameter-problem,
            nd-neighbor-solicit,
            nd-neighbor-advert,
          } counter accept

          ip protocol icmp icmp type {
            echo-request,
            echo-reply,
            destination-unreachable,
            time-exceeded,
            parameter-problem,
          } counter accept
        }

        # ICMP allowed from WANs: only errors needed for working PMTU and
        # connectivity, no pings. Replies to our own pings are established.
        chain icmp_wan {
          ip6 nexthdr icmpv6 icmpv6 type {
            destination-unreachable,
            packet-too-big,
            time-exceeded,
            parameter-problem,
          } counter accept

          ip protocol icmp icmp type {
            destination-unreachable,
            time-exceeded,
            parameter-problem,
          } counter accept
        }

        # Incoming connections to the router itself.
        chain input {
          type filter hook input priority 0
          policy drop

          ct state {established, related} counter accept
          ct state invalid counter drop

          # The router's own router advertisements, multicast to every
          # host on an advertising interface, loop back into input too.
          # Trusted LANs accept them and restricted LANs count them as
          # cross-VLAN traffic, but the internal dn42 chain logged each
          # one as a drop. They are never for us: discard them quietly
          # before any interface class sees them. The source is a
          # link-local address, so the local lookup needs the interface.
          ip6 nexthdr icmpv6 icmpv6 type nd-router-advert fib saddr . iif type local counter drop comment "router's own advertisements looped back"

          iifname $wans jump input_wan
          iifname "dn42e-*" jump input_dn42e
          iifname "dn42i-*" jump input_dn42i
          ${lib.optionalString icl ''iifname "icl-*" jump input_icl''}
          ${lib.optionalString iclBare ''
            # The GRETAP of a carrier-less interconnect, arriving on the LAN
            # which carries it. Both ends must sit inside one of the
            # prefixes an endpoint is drawn from, so each rule admits the
            # tunnel and nothing else.
            ip6 saddr $lab6 ip6 daddr $lab6 meta l4proto gre counter accept comment "bare interconnect GRE"
            ip6 saddr $carrier6 ip6 daddr $carrier6 meta l4proto gre counter accept comment "bare interconnect GRE"
          ''}

          jump icmp_lan

          # Always allow router solicitation from any LAN.
          ip6 nexthdr icmpv6 icmpv6 type nd-router-solicit counter accept

          iifname { lo, $trusted_lans } counter accept comment "localhost and trusted LANs to router"
          iifname $restricted_lans jump input_restricted

          limit rate 10/minute burst 20 packets log prefix "nft input reject: "
          counter name input_reject reject
        }

        # The router services the internet may reach, for input_wan and
        # for the restricted LANs, which may reach the router's public
        # addresses like anyone else. Anything not accepted here falls back
        # to the calling chain.
        chain services_wan {
          udp dport $tailscale_router counter accept comment "router WAN Tailscale"
          udp dport $tailscale_relay counter accept comment "router WAN peer relay"
          ${lib.optionalString (dn42Ports != [ ])
            ''udp dport { ${lib.concatStringsSep ", " dn42Ports} } counter accept comment "dn42 WireGuard peers"''
          }
          ${lib.optionalString (iclPorts != [ ])
            ''udp dport { ${lib.concatStringsSep ", " iclPorts} } counter accept comment "site interconnect carriers"''
          }

          # The dn42 peering page (see dn42-page.nix). New connections beyond
          # the rate fall through to the caller's drop; the page is a few
          # kilobytes, and nothing legitimate opens connections at that rate.
          tcp dport { $http, $https } limit rate 50/second burst 100 packets counter accept comment "router WAN peering page"
          # HTTP/3 for the same page: QUIC over UDP 443. The established
          # accept in input admits the rest of a flow, so only the first
          # datagram of each new connection is counted against the rate.
          udp dport $https limit rate 50/second burst 100 packets counter accept comment "router WAN peering page HTTP/3"

          # The dn42 peerfinder agent (see peerfinder.nix), internet-facing
          # on purpose: its backend connects to the WAN address recorded at
          # registration, either family. Every request must carry an HMAC
          # under the 32-byte registration key with a fresh nonce inside a
          # 30 s window, and targets are parsed as addresses before ping is
          # spawned, so the rest of the internet gets a closed connection.
          # Each accepted connection may cost a ping, and the backend
          # measures rarely, so the rate is far below the page's.
          tcp dport $peerfinder limit rate 5/second burst 10 packets counter accept comment "router WAN peerfinder"
        }

        # From the internet: silently drop everything not explicitly allowed.
        chain input_wan {
          jump icmp_wan

          # dn42 etiquette expects a peering endpoint to answer ping, and
          # peers measure the clearnet name before and after a tunnel. Only
          # the router itself: forward_wan still jumps icmp_wan, which has
          # no echo-request, so no LAN host becomes pingable. A flood falls
          # through the rate to the chain's drop.
          icmp type echo-request limit rate 10/second burst 20 packets counter accept comment "router WAN ping"
          icmpv6 type echo-request limit rate 10/second burst 20 packets counter accept comment "router WAN ping"

          # Default route via NDP.
          ip6 nexthdr icmpv6 icmpv6 type nd-router-advert counter accept
          ip6 nexthdr icmpv6 icmpv6 type {
            nd-neighbor-solicit,
            nd-neighbor-advert,
          } counter accept

          jump services_wan

          ip6 daddr fe80::/64 udp dport $dhcp6_client udp sport $dhcp6_server counter accept comment "router WAN DHCPv6"

          counter name wan_input_drop drop
        }

        ${lib.optionalString icl ''
          # From our other sites to the router itself. Both ends are ours,
          # but the wire carries dn42 too, so this stays narrow: the iBGP
          # session, its BFD, the resolver on our own address, and the
          # anycast clock. An
          # IGP which runs on the data link (IS-IS) never reaches this
          # family at all; one which runs over IP would need a rule here.
          chain input_icl {
            jump icmp_lan

            tcp dport $bgp counter accept comment "router interconnect BGP"
            udp dport $bfd_control counter accept comment "router interconnect BFD"
            ip daddr $site4 meta l4proto { tcp, udp } th dport $dns counter accept comment "router interconnect DNS"
            ip6 daddr $site6 meta l4proto { tcp, udp } th dport $dns counter accept comment "router interconnect DNS"
            # The anycast address alone: a client at another site whose
            # nearest node holding it is this router, on the same terms
            # the edges admit it from a circuit.
            ip6 daddr $anycast_ntp udp dport $ntp counter accept comment "router interconnect anycast NTP"
            ip daddr $anycast4_ntp udp dport $ntp counter accept comment "router interconnect anycast NTP"
            ip6 daddr $loopback6 tcp dport $http counter accept comment "router interconnect page"

            counter name icl_input_drop drop
          }
        ''}

        # From external dn42 peers to the router itself: BGP and BFD
        # sessions, pings and traceroutes (dn42 etiquette), the peering
        # page, and the nameserver for our domain. No router services
        # otherwise: this side faces networks we do not run.
        chain input_dn42e {
          jump icmp_lan

          tcp dport $bgp counter accept comment "router dn42 external BGP"
          udp dport $bfd_control counter accept comment "router dn42 external BFD"
          ${dn42Dns "external"}
          tcp dport { $http, $https } counter accept comment "router dn42 external peering page"
          udp dport $https counter accept comment "router dn42 external peering page HTTP/3"
          udp dport $ntp counter accept comment "router dn42 external NTP"

          # UDP traceroute to the router: probes climb from port 33434 and
          # the trace completes on a port unreachable from the destination
          # (time exceeded for earlier hops comes from forwarding). Nothing
          # listens in the range, but it sits inside the ephemeral ports,
          # where an accepted probe could reach whatever socket is bound
          # there; a reject states the intended reply instead.
          udp dport 33434-33534 counter reject with icmpx type port-unreachable comment "router dn42 external traceroute"

          limit rate 10/minute burst 20 packets log prefix "nft input dn42 drop: "
          counter name dn42_input_drop drop
        }

        # From our own dn42-addressed hosts to the router itself. The same
        # policy as the external side today, and deliberately a separate
        # chain: this is where router services for dn42 clients belong.
        # Only the authoritative nameserver so far; a resolver for this side
        # would be its own service, never the shared one.
        chain input_dn42i {
          jump icmp_lan

          # CoreRAD answers solicitations on the internal VLAN (see
          # corerad.nix); the input chain's blanket accept for them comes
          # after this jump, so it is repeated here.
          ip6 nexthdr icmpv6 icmpv6 type nd-router-solicit counter accept comment "router dn42 internal router solicitation"

          tcp dport $bgp counter accept comment "router dn42 internal BGP"
          udp dport $bfd_control counter accept comment "router dn42 internal BFD"
          ${dn42Dns "internal"}
          tcp dport { $http, $https } counter accept comment "router dn42 internal peering page"
          udp dport $https counter accept comment "router dn42 internal peering page HTTP/3"
          udp dport $ntp counter accept comment "router dn42 internal NTP"

          # tailscaled on both ends discovers its dn42 address as one more
          # candidate endpoint, so the hosts here probe the router's dn42
          # addresses at its tailscaled and peer relay ports. The tailnet
          # never rides dn42, and there is no per-interface opt-out to
          # give tailscaled; drop the probes without logging them.
          udp dport { $tailscale_router, $tailscale_relay } counter drop comment "router dn42 internal Tailscale probes"

          limit rate 10/minute burst 20 packets log prefix "nft input dn42 drop: "
          counter name dn42_input_drop drop
        }

        chain input_restricted {
          # Handle some services early due to need for multicast/broadcast.
          udp dport $dhcp4_server udp sport $dhcp4_client counter accept comment "router restricted DHCPv4"
          iifname iot0 udp dport $mdns udp sport $mdns counter accept comment "router iot0 mDNS reflection"

          # The router's public services are public from here too: a
          # packet for any of the router's own addresses, its WAN ones
          # included, may reach what the internet may. The WAN addresses
          # are not inventory data, so the test is the address being local
          # rather than a set.
          fib daddr type local jump services_wan

          # The anycast addresses are this router's too, but they sit on no
          # segment, so the cross-VLAN test below -- keyed on the interface
          # and the router's address on it -- can never hold them, and a
          # query to one would be dropped as an attempt to leave the VLAN.
          ip6 daddr $anycast_dns meta l4proto { tcp, udp } th dport $dns counter accept comment "router restricted anycast DNS"
          ip6 daddr $anycast_ntp udp dport $ntp counter accept comment "router restricted anycast NTP"
          ip daddr $anycast4_dns meta l4proto { tcp, udp } th dport $dns counter accept comment "router restricted anycast DNS"
          ip daddr $anycast4_ntp udp dport $ntp counter accept comment "router restricted anycast NTP"

          # Drop traffic trying to cross VLANs or broadcast.
          iifname . ip daddr != @router_v4 counter name restricted_crossvlan_drop drop comment "traffic leaving IPv4 VLAN"
          iifname . ip6 daddr != @router_v6 counter name restricted_crossvlan_drop drop comment "traffic leaving IPv6 VLAN"

          # Allow only necessary router-provided services.
          tcp dport $dns counter accept comment "router restricted TCP"
          udp dport $dns counter accept comment "router restricted UDP"
          udp dport $ntp counter accept comment "router restricted NTP"
          udp dport $tailscale_relay counter accept comment "router restricted peer relay"

          limit rate 10/minute burst 20 packets log prefix "nft input restricted drop: "
          counter name restricted_input_drop drop
        }

        chain output {
          type filter hook output priority 0
          policy accept
          counter accept
        }

        chain forward {
          type filter hook forward priority 0
          policy drop

          # Clamp TCP MSS to the dn42 tunnel MTU in both directions, before
          # the established shortcut so inbound SYN/ACKs are also clamped.
          oifname { "dn42e-*", "dn42i-*", "icl-*" } tcp flags syn tcp option maxseg size set rt mtu comment "dn42 MSS clamp out"
          iifname { "dn42e-*", "dn42i-*", "icl-*" } tcp flags syn tcp option maxseg size set rt mtu comment "dn42 MSS clamp in"

          ct state {established, related} counter accept

          # dn42 routing between peers is commonly asymmetric, so tunnel to
          # tunnel transit is accepted before the conntrack invalid drop,
          # which would discard flows whose other direction takes a
          # different peer.
          iifname "dn42e-*" oifname "dn42e-*" counter accept comment "dn42 transit"

          ${lib.optionalString icl ''
            # Site traffic passing between circuits, for the same reason:
            # a flow whose return takes another circuit or another site is
            # seen here in one direction only, and the invalid drop would
            # discard it. Both ends of such a flow are ours, so the test is
            # our own space on each side.
            iifname "icl-*" oifname "icl-*" ip saddr $site4 ip daddr $site4 counter accept comment "site transit between circuits"
            iifname "icl-*" oifname "icl-*" ip6 saddr $site6 ip6 daddr $site6 counter accept comment "site transit between circuits"
          ''}
          ct state invalid counter drop

          iifname $wans jump forward_wan

          # Our own dn42 hosts face dn42 the way the LANs face the internet:
          # they initiate toward it, and it reaches them only through the
          # established shortcut above and what forward_dn42i allows. No
          # asymmetry to allow for on this leg: the router is the only path
          # to our hosts, so conntrack sees both directions of every flow.
          iifname "dn42i-*" oifname "dn42e-*" counter accept comment "dn42 internal to external"
          iifname "dn42e-*" oifname "dn42i-*" jump forward_dn42i

          # A debug segment probes from here, above the drops that hold the
          # restricted LANs to the internet: echo and the errors a trace
          # reads, in the outbound direction only. What comes back arrives
          # as established or related, and every other protocol still meets
          # those drops, so no service becomes reachable.
          ${lib.optionalString (debugLans != [ ]) "iifname $debug_lans jump icmp_lan"}

          ${lib.optionalString icl ''
            # A restricted LAN's own address is inside the site prefix the
            # rules below admit, and a circuit is not a LAN, so without this
            # those segments reach another site's machines on every port
            # while being denied every LAN here. The anycast services are
            # the exception they are given on this router, and answering
            # them elsewhere is a forward rather than an input once another
            # node holds the address.
            iifname $restricted_lans oifname "icl-*" ip6 daddr $anycast_dns meta l4proto { tcp, udp } th dport $dns counter accept comment "restricted LAN anycast DNS across a circuit"
            iifname $restricted_lans oifname "icl-*" ip6 daddr $anycast_ntp udp dport $ntp counter accept comment "restricted LAN anycast NTP across a circuit"
            iifname $restricted_lans oifname "icl-*" ip daddr $anycast4_dns meta l4proto { tcp, udp } th dport $dns counter accept comment "restricted LAN anycast DNS across a circuit"
            iifname $restricted_lans oifname "icl-*" ip daddr $anycast4_ntp udp dport $ntp counter accept comment "restricted LAN anycast NTP across a circuit"
            iifname $restricted_lans oifname "icl-*" counter name restricted_forward_drop drop comment "restricted LANs to another site"

            # The interconnect is classified by address, not by interface:
            # our own space crosses it as site traffic, dn42 space crosses
            # it under dn42's own rules, and anything else matches nothing
            # and meets this chain's drop. Placed above the dn42 drop below
            # so that transit to another site is not caught by it.
            #
            # Inbound, a source in our own space is not by itself a trusted
            # party: every segment at another site draws from that prefix,
            # restricted ones included. What a far site may initiate toward
            # this one is named per service in forward_icl; what this site
            # initiates across a circuit returns as established.
            iifname "icl-*" ip daddr $site4 jump forward_icl
            iifname "icl-*" ip6 daddr $site6 jump forward_icl
            oifname "icl-*" ip saddr $site4 ip daddr $site4 counter accept comment "interconnect site out"
            oifname "icl-*" ip6 saddr $site6 ip6 daddr $site6 counter accept comment "interconnect site out"

            # Transit is dn42 reaching dn42. Our own space is never its
            # destination -- that is the class above, which requires both
            # ends to be ours -- and a site with a loopback on the circuit
            # would otherwise be reachable from dn42 through this rule.
            iifname "dn42e-*" oifname "icl-*" ip daddr $site4 counter name dn42_forward_drop drop comment "dn42 to another site"
            iifname "dn42e-*" oifname "icl-*" ip6 daddr $site6 counter name dn42_forward_drop drop comment "dn42 to another site"

            iifname "icl-*" oifname "dn42e-*" counter accept comment "dn42 transit via interconnect"
            iifname "dn42e-*" oifname "icl-*" counter accept comment "dn42 transit to interconnect"
            iifname "dn42i-*" oifname "icl-*" counter accept comment "dn42 internal to interconnect"
            iifname "icl-*" oifname "dn42i-*" jump forward_dn42i
          ''}

          # dn42, ours or anyone's, may never initiate toward LANs or WANs.
          iifname { "dn42e-*", "dn42i-*" } counter name dn42_forward_drop drop comment "dn42 to LANs and WANs"

          # Restricted LANs may only initiate connections to the internet:
          # never to trusted LANs, nor to each other.
          iifname $restricted_lans oifname $all_lans counter name restricted_forward_drop drop comment "restricted LANs to LANs"

          jump icmp_lan

          iifname $trusted_lans oifname $wans counter accept comment "trusted LANs to all WANs"
          iifname $trusted_lans oifname $all_lans counter accept comment "trusted LANs to all LANs"
          iifname $restricted_lans oifname $wans counter accept comment "restricted LANs only to WANs"

          limit rate 10/minute burst 20 packets log prefix "nft forward reject: "
          counter name forward_reject reject
        }

        # From dn42 to our own hosts: pings and ICMP errors; silently drop
        # the rest. A service one of our hosts offers to dn42 is opened
        # here, per host and port, the way forward_wan opens Tailscale.
        chain forward_dn42i {
          jump icmp_lan

          counter name dn42_inbound_drop drop
        }

        ${lib.optionalString icl ''
          # From another site into this one's LANs: pings and ICMP errors,
          # and the services a far site is expected to initiate toward, by
          # host and port from the set the inventory renders. Logged, since
          # a service missing from that set is the likeliest thing to be
          # looked for here.
          chain forward_icl {
            jump icmp_lan

            ip6 daddr . tcp dport @icl_services_v6 counter accept comment "site services from a circuit"

            limit rate 10/minute burst 20 packets log prefix "nft forward icl drop: "
            counter name icl_forward_drop drop
          }
        ''}

        # From the internet to LANs: only ICMP errors and Tailscale to
        # specific hosts; silently drop the rest.
        chain forward_wan {
          jump icmp_wan

          ip daddr . udp dport @tailscale_v4 counter accept comment "Tailscale IPv4 forwarding"
          ip6 daddr . udp dport @tailscale_v6 counter accept comment "Tailscale IPv6 forwarding"

          counter name wan_forward_drop drop
        }
      }

      # Traffic accounting, hooked after the filter table's chains so only
      # accepted traffic is counted. The filter's early established shortcut
      # hides most bytes from its per-rule counters; these chains see every
      # packet regardless of connection state.
      table inet accounting {
        ${lib.concatMapStrings (lan: ''
          counter ${lan}_wan_out {}
          counter ${lan}_wan_in {}
        '') lans}

        # Per-host WAN accounting: hosts are learned from traffic as dynamic
        # set elements, each carrying its own counter. update refreshes an
        # element's timeout on every packet, so an element expires only after
        # total silence for the timeout. The timeout just needs to outlive
        # the scrape interval comfortably: once Prometheus has seen a count,
        # expiry loses nothing (a returning host restarts at zero, which
        # increase() absorbs as a counter reset), and a short timeout stops
        # rotated IPv6 privacy addresses and departed hosts from lingering
        # as stale series. The forward hook sits inside NAT and DNAT, so
        # both directions see real LAN addresses.
        ${lib.concatMapStrings (proto: ''
          set host${proto.v}_wan_out {
            type ${proto.type}
            size 4096
            flags dynamic, timeout
            timeout 5m
            counter
          }
          set host${proto.v}_wan_in {
            type ${proto.type}
            size 4096
            flags dynamic, timeout
            timeout 5m
            counter
          }
        '') protos}

        # dn42 traffic by what the router is to it: transit between peers'
        # tunnels, which passes through; our own hosts' traffic on the
        # internal VLANs; and what terminates on the router itself, the BGP
        # and BFD sessions and pings. Transit is counted once, on the way
        # through; the other two are split by direction, from the router's
        # or our hosts' point of view.
        counter dn42_transit {}
        counter dn42_internal_in {}
        counter dn42_internal_out {}
        counter dn42_router_in {}
        counter dn42_router_out {}

        chain forward {
          type filter hook forward priority 5
          policy accept

          ${lib.concatMapStrings (lan: ''
            iifname ${lan} oifname $wans counter name ${lan}_wan_out
            iifname $wans oifname ${lan} counter name ${lan}_wan_in
          '') lans}

          ${lib.concatMapStrings (proto: ''
            iifname $all_lans oifname $wans update @host${proto.v}_wan_out { ${proto.outKey} }
            iifname $wans oifname $all_lans update @host${proto.v}_wan_in { ${proto.inKey} }
          '') protos}

          iifname "dn42e-*" oifname "dn42e-*" counter name dn42_transit
          iifname "dn42e-*" oifname "dn42i-*" counter name dn42_internal_in
          iifname "dn42i-*" oifname "dn42e-*" counter name dn42_internal_out
        }

        # Terminating traffic, hooked after the filter's input chain the
        # same way, so only what it accepted is counted; the router's own
        # output is unfiltered.
        chain input {
          type filter hook input priority 5
          policy accept

          iifname "dn42e-*" counter name dn42_router_in
        }

        chain output {
          type filter hook output priority 5
          policy accept

          oifname "dn42e-*" counter name dn42_router_out
        }
      }

      table ip nat {
        # Inbound UDP port to LAN host, for Tailscale.
        map tailscale_dnat {
          type inet_service : ipv4_addr
        }

        chain prerouting {
          type nat hook prerouting priority 0
          iifname $wans dnat to udp dport map @tailscale_dnat comment "Tailscale UDPv4 DNAT"
        }

        chain postrouting {
          type nat hook postrouting priority 0
          # Masquerade IPv4 to all WANs.
          oifname $wans masquerade
        }
      }
    '';
  };
}
