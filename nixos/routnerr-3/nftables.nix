{
  config,
  lib,
  pkgs,
  ...
}:

let
  inventory = config.homelab.inventory;

  # Interface groups. Restricted LANs (guest, IoT, dev) may only reach the
  # internet and a few router services; trusted LANs may reach everything.
  wans = [
    "wan0"
    "wan1"
  ];
  trusted = with inventory.interfaces; [
    mgmt0
    lan0
    { name = "ts0"; }
  ];
  restricted = with inventory.interfaces; [
    guest0
    iot0
    dev0
  ];

  # Produces an nftables set of interface names.
  ifnames = ifis: "{ ${lib.concatMapStringsSep ", " (ifi: ifi.name or ifi) ifis} }";

  # Different tailscaled ports for different devices to avoid messing with
  # poking nftables firewall holes with miniupnpd or similar.
  tailscale = {
    router = 41461;
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
      add element ip nat tailscale_dnat { ${forwards (ts: "${toString ts.port} : ${ts.host.ipv4}")} }
    '';

  nft = "${pkgs.nftables}/bin/nft";
  elementsFile = config.sops.templates."nftables-inventory.conf".path;

  # Prometheus exporter for the named counters and per-host set counters in
  # the accounting rules below, read via netlink at scrape time; built from
  # source in this repository (not packaged in nixpkgs). The server scrapes
  # it on port 9630, per the exporter default port allocations wiki; see
  # nixos/servnerr-4/prometheus.nix.
  # Go 1.27 from unstable, matching the toolchain used everywhere else.
  nftables_exporter = (pkgs.buildGoModule.override { go = pkgs.unstable.go_1_27; }) {
    pname = "nftables_exporter";
    version = "0.1.0";
    src = ../../go/internal/nftables_exporter;
    vendorHash = "sha256-IOX2K4bBnhDq88PBU1yOmpZhBa3OXrgIohBBpmv9LZ0=";
  };

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

  systemd.services.nftables-exporter = {
    description = "Prometheus nftables exporter";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      ExecStart = "${nftables_exporter}/bin/nftables_exporter";
      Restart = "always";

      # Reading nftables over netlink needs CAP_NET_ADMIN; everything else
      # is locked down.
      DynamicUser = true;
      AmbientCapabilities = [ "CAP_NET_ADMIN" ];
      CapabilityBoundingSet = [ "CAP_NET_ADMIN" ];
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      ProtectKernelTunables = true;
      ProtectControlGroups = true;
      RestrictNamespaces = true;
    };
  };

  networking.nftables = {
    enable = true;
    ruleset = ''
      define wans = ${ifnames wans}
      define trusted_lans = ${ifnames trusted}
      define restricted_lans = ${ifnames restricted}
      define all_lans = ${ifnames (trusted ++ restricted)}
      define physical_lans = ${ifnames (lib.filter (ifi: ifi ? vlan) (trusted ++ restricted))}

      define dns = 53
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
        counter input_reject {}
        counter wan_input_drop {}
        counter restricted_crossvlan_drop {}
        counter restricted_input_drop {}
        counter restricted_forward_drop {}
        counter forward_reject {}
        counter wan_forward_drop {}

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

        # Drop packets from physical LANs whose source address does not belong
        # on the interface they arrived on. The kernel exempts DHCP/DAD
        # (unspecified source to broadcast/multicast).
        chain prerouting {
          type filter hook prerouting priority raw
          policy accept

          iifname $physical_lans fib saddr . iif oif missing limit rate 10/minute burst 20 packets log prefix "nft spoofed drop: "
          iifname $physical_lans fib saddr . iif oif missing counter name spoofed_drop drop comment "spoofed source"
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

          iifname $wans jump input_wan

          jump icmp_lan

          # Always allow router solicitation from any LAN.
          ip6 nexthdr icmpv6 icmpv6 type nd-router-solicit counter accept

          iifname { lo, $trusted_lans } counter accept comment "localhost and trusted LANs to router"
          iifname $restricted_lans jump input_restricted

          limit rate 10/minute burst 20 packets log prefix "nft input reject: "
          counter name input_reject reject
        }

        # From the internet: silently drop everything not explicitly allowed.
        chain input_wan {
          jump icmp_wan

          # Default route via NDP.
          ip6 nexthdr icmpv6 icmpv6 type nd-router-advert counter accept
          ip6 nexthdr icmpv6 icmpv6 type {
            nd-neighbor-solicit,
            nd-neighbor-advert,
          } counter accept

          udp dport $tailscale_router counter accept comment "router WAN Tailscale"
          udp dport $tailscale_relay counter accept comment "router WAN peer relay"

          ip6 daddr fe80::/64 udp dport $dhcp6_client udp sport $dhcp6_server counter accept comment "router WAN DHCPv6"

          counter name wan_input_drop drop
        }

        chain input_restricted {
          # Handle some services early due to need for multicast/broadcast.
          udp dport $dhcp4_server udp sport $dhcp4_client counter accept comment "router restricted DHCPv4"
          iifname iot0 udp dport $mdns udp sport $mdns counter accept comment "router iot0 mDNS reflection"

          # Drop traffic trying to cross VLANs or broadcast.
          iifname . ip daddr != @router_v4 counter name restricted_crossvlan_drop drop comment "traffic leaving IPv4 VLAN"
          iifname . ip6 daddr != @router_v6 counter name restricted_crossvlan_drop drop comment "traffic leaving IPv6 VLAN"

          # Allow only necessary router-provided services.
          tcp dport $dns counter accept comment "router restricted TCP"
          udp dport $dns counter accept comment "router restricted UDP"
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

          ct state {established, related} counter accept
          ct state invalid counter drop

          iifname $wans jump forward_wan

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

        # From the internet to LANs: only ICMP errors and Tailscale to
        # specific hosts; silently drop the rest.
        chain forward_wan {
          jump icmp_wan

          ip daddr . udp dport @tailscale_v4 counter accept comment "Tailscale IPv4 forwarding"
          ip6 daddr . udp dport @tailscale_v6 counter accept comment "Tailscale IPv6 forwarding"

          counter name wan_forward_drop drop
        }
      }

      # Traffic accounting, hooked after the filter table's forward chain so
      # only accepted traffic is counted. The filter's early established
      # shortcut hides most bytes from its per-rule counters; this chain sees
      # every forwarded packet regardless of connection state.
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
