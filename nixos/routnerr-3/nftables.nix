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

      table inet filter {
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

          iifname $physical_lans fib saddr . iif oif missing counter drop comment "spoofed source"
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

          ip saddr {
            49.64.0.0/11,
            218.92.0.0/16,
            222.184.0.0/13,
          } counter drop comment "malicious subnets"

          iifname $wans jump input_wan

          jump icmp_lan

          # Always allow router solicitation from any LAN.
          ip6 nexthdr icmpv6 icmpv6 type nd-router-solicit counter accept

          iifname { lo, $trusted_lans } counter accept comment "localhost and trusted LANs to router"
          iifname $restricted_lans jump input_restricted

          limit rate 10/minute burst 20 packets log prefix "nft input reject: "
          counter reject
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

          ip6 daddr fe80::/64 udp dport $dhcp6_client udp sport $dhcp6_server counter accept comment "router WAN DHCPv6"

          counter drop
        }

        chain input_restricted {
          # Handle some services early due to need for multicast/broadcast.
          udp dport $dhcp4_server udp sport $dhcp4_client counter accept comment "router restricted DHCPv4"
          udp dport $mdns udp sport $mdns counter accept comment "router restricted mDNS"

          # Drop traffic trying to cross VLANs or broadcast.
          iifname . ip daddr != @router_v4 counter drop comment "traffic leaving IPv4 VLAN"
          iifname . ip6 daddr != @router_v6 counter drop comment "traffic leaving IPv6 VLAN"

          # Allow only necessary router-provided services.
          tcp dport $dns counter accept comment "router restricted TCP"
          udp dport $dns counter accept comment "router restricted UDP"

          limit rate 10/minute burst 20 packets log prefix "nft input restricted drop: "
          counter drop
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
          iifname $restricted_lans oifname $all_lans counter drop comment "restricted LANs to LANs"

          jump icmp_lan

          iifname $trusted_lans oifname $wans counter accept comment "trusted LANs to all WANs"
          iifname $trusted_lans oifname $all_lans counter accept comment "trusted LANs to all LANs"
          iifname $restricted_lans oifname $wans counter accept comment "restricted LANs only to WANs"

          limit rate 10/minute burst 20 packets log prefix "nft forward reject: "
          counter reject
        }

        # From the internet to LANs: only ICMP errors and Tailscale to
        # specific hosts; silently drop the rest.
        chain forward_wan {
          jump icmp_wan

          ip daddr . udp dport @tailscale_v4 counter accept comment "Tailscale IPv4 forwarding"
          ip6 daddr . udp dport @tailscale_v6 counter accept comment "Tailscale IPv6 forwarding"

          counter drop
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
