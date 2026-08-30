{
  config,
  lib,
  pkgs,
  ...
}:

let
  inventory = config.homelab.inventory;

  # Port definitions.
  ports = {
    dns = "53";
    dhcp4_server = "67";
    dhcp4_client = "68";
    dhcp6_client = "546";
    dhcp6_server = "547";
    mdns = "5353";
    # Different tailscaled ports for different devices to avoid messing with
    # poking nftables firewall holes with miniupnpd or similar.
    tailscale = {
      router = "41461";
      desktop = "41642";
      work_laptop = "41643";
    };
  };

  # Produces a CSV list of interface names.
  mkCSV = lib.concatMapStrings (ifi: "${ifi.name}, ");

  # WAN interfaces.
  all_wans = "wan0, wan1";

  # LAN interfaces, segmented into trusted, limited, and untrusted groups.
  trusted_lans = with inventory.interfaces; [
    mgmt0
    lan0
    { name = "ts0"; }
  ];
  limited_lans = with inventory.interfaces; [ guest0 ];
  untrusted_lans = with inventory.interfaces; [ iot0 ];

  # LAN hosts which accept inbound Tailscale traffic from the WAN, forwarded
  # by IPv4 DNAT and IPv6 routing.
  tailscale_hosts = with inventory.hosts; [
    {
      host = nerr-4;
      port = ports.tailscale.desktop;
      comment = "desktop";
    }
    {
      host = psframework;
      port = ports.tailscale.work_laptop;
      comment = "work laptop";
    }
  ];

  # Addresses are secrets from the inventory, so rules reference named sets
  # which are populated at activation time from a rendered file. Empty sets
  # fail closed.
  setName = prefix: name: "${prefix}_${lib.replaceStrings [ "-" "." ] [ "_" "_" ] name}";
  routerSet = ifi: setName "router" ifi.name;
  tailscaleSet = ts: setName "tailscale" ts.host.name;

  sets = ''
    ${lib.concatMapStrings (ifi: ''
      set ${routerSet ifi}_v4 {
        type ipv4_addr
      }
      set ${routerSet ifi}_v6 {
        type ipv6_addr
      }
    '') (limited_lans ++ untrusted_lans)}

    ${lib.concatMapStrings (ts: ''
      set ${tailscaleSet ts}_v4 {
        type ipv4_addr
      }
      set ${tailscaleSet ts}_v6 {
        type ipv6_addr
      }
    '') tailscale_hosts}
  '';

  # Set elements rendered from the inventory secrets.
  elements =
    lib.concatMapStrings (ifi: ''
      add element inet filter ${routerSet ifi}_v4 { ${ifi.ipv4} }
      add element inet filter ${routerSet ifi}_v6 { ${ifi.lla}, ${ifi.ula} }
    '') (limited_lans ++ untrusted_lans)
    + lib.concatMapStrings (ts: ''
      add element inet filter ${tailscaleSet ts}_v4 { ${ts.host.ipv4} }
      add element inet filter ${tailscaleSet ts}_v6 { ${ts.host.gua} }
      add element ip nat tailscale_dnat { ${ts.port} : ${ts.host.ipv4} }
    '') tailscale_hosts;

  # ICMP filtering.
  icmp_rules = ''
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
      table inet filter {
        ${sets}

        # Incoming connections to router itself.
        chain input {
          type filter hook input priority 0
          policy drop

          ct state {established, related} counter accept
          ct state invalid counter drop

          # Malicious subnets.
          ip saddr {
            49.64.0.0/11,
            218.92.0.0/16,
            222.184.0.0/13,
          } counter drop comment "malicious subnets"

          # ICMPv4/6.
          ${icmp_rules}

          # Allow all WANs to selectively communicate with the router.
          iifname {
            ${all_wans}
          } jump input_wan

          # Always allow router solicitation from any LAN.
          ip6 nexthdr icmpv6 icmpv6 type nd-router-solicit counter accept

          # Allow localhost and trusted LANs to communicate with router.
          iifname {
            lo,
            ${mkCSV trusted_lans}
          } counter accept comment "localhost and trusted LANs to router"

          # Limit the communication abilities of limited and untrusted LANs.
          iifname {
            ${mkCSV limited_lans}
            ${mkCSV untrusted_lans}
          } jump input_limited_untrusted

          counter reject
        }

        chain input_wan {
          # Default route via NDP.
          ip6 nexthdr icmpv6 icmpv6 type nd-router-advert counter accept

          # router UDP
          udp dport {
            ${ports.tailscale.router},
          } counter accept comment "router WAN UDP"

          # router DHCPv6 client
          ip6 daddr fe80::/64 udp dport ${ports.dhcp6_client} udp sport ${ports.dhcp6_server} counter accept comment "router WAN DHCPv6"

          counter reject
        }

        chain input_limited_untrusted {
          # Handle some services early due to need for multicast/broadcast.
          udp dport ${ports.dhcp4_server} udp sport ${ports.dhcp4_client} counter accept comment "router untrusted DHCPv4"

          udp dport ${ports.mdns} udp sport ${ports.mdns} counter accept comment "router untrusted mDNS"

          # Drop traffic trying to cross VLANs or broadcast.
          ${lib.concatMapStrings (ifi: ''
            iifname ${ifi.name} ip daddr != @${routerSet ifi}_v4 counter drop comment "${ifi.name} traffic leaving IPv4 VLAN"
            iifname ${ifi.name} ip6 daddr != @${routerSet ifi}_v6 counter drop comment "${ifi.name} traffic leaving IPv6 VLAN"
          '') (limited_lans ++ untrusted_lans)}

          # Allow only necessary router-provided services.
          tcp dport {
            ${ports.dns},
          } counter accept comment "router untrusted TCP"

          udp dport {
            ${ports.dns},
          } counter accept comment "router untrusted UDP"

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

          # Untrusted/limited LANs to trusted LANs.
          iifname {
            ${mkCSV limited_lans}
            ${mkCSV untrusted_lans}
          } oifname {
            ${mkCSV trusted_lans}
          } jump forward_limited_untrusted_lan_trusted_lan

          # We still want to allow limited/untrusted LANs to have working ICMP
          # to the internet as a whole, just not to any trusted LANs.
          ${icmp_rules}

          # Forwarding between different interface groups.

          # Trusted source LANs.
          iifname {
            ${mkCSV trusted_lans}
          } oifname {
            ${all_wans}
          } counter accept comment "Allow trusted LANs to all WANs";

          iifname {
            ${mkCSV trusted_lans}
          } oifname {
            ${mkCSV trusted_lans},
            ${mkCSV limited_lans},
            ${mkCSV untrusted_lans},
          } counter accept comment "Allow trusted LANs to reach all LANs";

          # Limited/guest LANs to WAN.
          iifname {
            ${mkCSV limited_lans}
            ${mkCSV untrusted_lans}
          } oifname {
            ${all_wans}
          } counter accept comment "Allow limited LANs only to WANs";

          # All WANs to trusted LANs.
          iifname {
            ${all_wans}
          } oifname {
            ${mkCSV trusted_lans}
          } jump forward_wan_trusted_lan

          # All WANs to limited/untrusted LANs.
          iifname {
            ${all_wans}
          } oifname {
            ${mkCSV limited_lans}
            ${mkCSV untrusted_lans}
          } jump forward_wan_limited_untrusted_lan

          counter reject
        }

        chain forward_limited_untrusted_lan_trusted_lan {
          # Only allow established connections from trusted LANs.
          ct state {established, related} counter accept
          ct state invalid counter drop

          counter drop
        }

        chain forward_wan_trusted_lan {
          ct state {established, related} counter accept
          ct state invalid counter drop

          # Tailscale forwarding.
          ${lib.concatMapStrings (ts: ''
            ip daddr @${tailscaleSet ts}_v4 udp dport ${ts.port} counter accept comment "${ts.comment} IPv4 Tailscale"
            ip6 daddr @${tailscaleSet ts}_v6 udp dport ${ts.port} counter accept comment "${ts.comment} IPv6 Tailscale"
          '') tailscale_hosts}

          counter reject
        }

        chain forward_wan_limited_untrusted_lan {
          ct state {established, related} counter accept
          ct state invalid counter drop

          counter reject
        }
      }

      table ip nat {
        # Inbound UDP port to LAN host, for Tailscale.
        map tailscale_dnat {
          type inet_service : ipv4_addr
        }

        chain prerouting {
          type nat hook prerouting priority 0

          # NAT IPv4 to all WANs.
          iifname {
            ${all_wans}
          } jump prerouting_wans
          accept
        }

        chain prerouting_wans {
          dnat to udp dport map @tailscale_dnat comment "Tailscale UDPv4 DNAT"

          accept
        }

        chain postrouting {
          type nat hook postrouting priority 0
          # Masquerade IPv4 to all WANs.
          oifname {
            ${all_wans}
          } masquerade
        }
      }
    '';
  };
}
