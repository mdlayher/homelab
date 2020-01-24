{ config, lib, ... }:

let
  vars = import ./vars.nix;

  guest0 = vars.interfaces.guest0;
  iot0 = vars.interfaces.iot0;
  lab0 = vars.interfaces.lab0;
  lan0 = vars.interfaces.lan0;
  wan0 = vars.interfaces.wan0;
  wg0 = vars.interfaces.wg0;

  ports = {
    dns = "53";
    dhcp4_server = "67";
    dhcp4_client = "68";
    dhcp6_client = "546";
    dhcp6_server = "547";
    http = "80";
    https = "443";
    imaps = "993";
    ntp = "123";
    pop3s = "995";
    plex = "32400";
    smtp = "587";
    ssh = "22";
    wireguard = "51820";
  };

in {
  networking.nftables = {
    enable = true;
    ruleset = ''
      table inet filter {
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

          # ICMP
          ip6 nexthdr icmpv6 icmpv6 type {
            echo-request,
            destination-unreachable,
            packet-too-big,
            time-exceeded,
            parameter-problem,
            nd-neighbor-solicit,
            nd-neighbor-advert,
          } counter accept

          ip protocol icmp icmp type {
            echo-request,
            destination-unreachable,
            time-exceeded,
            parameter-problem,
          } counter accept

          # Allow WAN to selectively communicate with the router.
          iifname ${wan0.name} jump input_wan

          # Always allow router solicitation from any LAN.
          ip6 nexthdr icmpv6 icmpv6 type nd-router-solicit counter accept

          # Allow localhost and trusted LANs to communicate with router.
          iifname {
            lo,
            ${lan0.name},
            ${lab0.name},
            ${wg0.name},
          } counter accept

          # Limit the communication abilities of untrusted LANs.
          iifname {
            ${guest0.name},
            ${iot0.name},
          } jump input_untrusted

          counter reject
        }

        chain input_wan {
          # Default route via NDP.
          ip6 nexthdr icmpv6 icmpv6 type nd-router-advert counter accept

          # router TCP
          tcp dport {
            ${ports.http},
            ${ports.https},
            ${ports.ssh},
          } counter accept comment "router WAN TCP"

          # router UDP
          udp dport {
            ${ports.wireguard},
          } counter accept comment "router WAN UDP"

          # router DHCPv6 client
          ip6 daddr fe80::/64 udp dport ${ports.dhcp6_client} udp sport ${ports.dhcp6_server} counter accept comment "router WAN DHCPv6"

          counter reject
        }

        chain input_untrusted {
          # Handle DHCP early due to need for broadcast.
          udp dport ${ports.dhcp4_server} udp sport ${ports.dhcp4_client} counter accept comment "router untrusted DHCPv4"

          # Drop traffic trying to cross VLANs or broadcast.
          iifname ${guest0.name} ip daddr != ${guest0.ipv4} counter drop comment "Guest leaving IPv4 VLAN"

          iifname ${guest0.name} ip6 daddr != {
            ${guest0.ipv6.lla},
            ${guest0.ipv6.ula},
          } counter drop comment "Guest leaving IPv6 VLAN"

          iifname ${iot0.name} ip daddr != ${iot0.ipv4} counter drop comment "IoT leaving IPv4 VLAN"

          iifname ${iot0.name} ip6 daddr != {
            ${iot0.ipv6.lla},
            ${iot0.ipv6.ula},
          } counter drop comment "IoT leaving IPv6 VLAN"

          # Allow only necessary router-provided services.
          tcp dport {
            ${ports.dns},
          } counter accept comment "router untrusted TCP"

          udp dport {
            ${ports.dns},
          } counter accept comment "router untrusted UDP"

          counter drop
        }

        # Allow all outgoing router connections.
        chain output {
          type filter hook output priority 0
          policy accept

          counter accept
        }

        chain forward {
          type filter hook forward priority 0
          policy drop

          # ICMP
          ip6 nexthdr icmpv6 icmpv6 type {
            echo-request,
            destination-unreachable,
            packet-too-big,
            time-exceeded,
            parameter-problem,
            nd-neighbor-solicit,
            nd-neighbor-advert,
          } counter accept

          ip protocol icmp icmp type {
            echo-request,
            destination-unreachable,
            time-exceeded,
            parameter-problem,
          } counter accept

          # WireGuard tunnel is treated as a trusted LAN.

          # Trusted LANs to WAN.
          iifname {
            ${lan0.name},
            ${lab0.name},
            ${wg0.name},
          } oifname ${wan0.name} jump forward_trusted_lan_wan

          # Limited/guest LANs to WAN.
          iifname {
            ${guest0.name},
          } oifname ${wan0.name} jump forward_limited_lan_wan

          # Untrusted LANs to WAN.
          iifname {
            ${iot0.name},
          } oifname ${wan0.name} jump forward_untrusted_lan_wan

          # Trusted bidirectional LAN.
          iifname {
            ${lan0.name},
            ${lab0.name},
            ${wg0.name},
          } oifname {
            ${lan0.name},
            ${lab0.name},
            ${wg0.name},
          } jump forward_trusted_lan_lan

          # WAN to trusted LANs.
          iifname ${wan0.name} oifname {
            ${lan0.name},
            ${lab0.name},
            ${wg0.name},
          } jump forward_wan_trusted_lan

          # WAN to untrusted LANs.
          iifname ${wan0.name} oifname {
            ${guest0.name},
            ${iot0.name},
          } jump forward_wan_untrusted_lan

          counter reject
        }

        chain forward_trusted_lan_lan {
          counter accept
        }

        chain forward_trusted_lan_wan {
          counter accept
        }

        chain forward_limited_lan_wan {
          # Forward typical network services.

          tcp dport {
            ${ports.dns},
            ${ports.http},
            ${ports.https},
            ${ports.imaps},
            ${ports.pop3s},
            ${ports.smtp},
            ${ports.ssh},
          } counter accept comment "limited TCP"

          udp dport {
            ${ports.dns},
            ${ports.ntp},
            ${ports.wireguard},
          } counter accept comment "limited UDP"

          counter drop
        }

        chain forward_untrusted_lan_wan {
          # Forward only necessary internet services.
          tcp dport {
            ${ports.http},
            ${ports.https},
          } counter accept comment "untrusted TCP HTTP(S)"

          counter drop
        }

        chain forward_wan_trusted_lan {
          ct state {established, related} counter accept
          ct state invalid counter drop

          # SSH for internal machines.
          ip6 daddr {
            ${lib.concatMapStrings (host: "${host.ipv6.gua}, ") vars.hosts.servers}
          } tcp dport ${ports.ssh} counter accept comment "IPv6 SSH"

          # Plex running on server.
          ip daddr ${vars.server_ipv4} tcp dport ${ports.plex} counter accept comment "server IPv4 Plex"
          ip6 daddr ${vars.server_ipv6} tcp dport ${ports.plex} counter accept comment "server IPv6 Plex"

          counter reject
        }

        chain forward_wan_untrusted_lan {
          ct state {established, related} counter accept
          ct state invalid counter drop

          counter reject
        }
      }

      table ip nat {
        chain prerouting {
          type nat hook prerouting priority 0

          iifname ${wan0.name} jump prerouting_wan0
          accept
        }

        chain prerouting_wan0 {
          tcp dport {
            ${ports.plex},
          } dnat ${vars.server_ipv4} comment "server TCPv4 DNAT"

          udp dport {
            ${ports.dns},
          } redirect to ${ports.wireguard} comment "router IPv4 WireGuard DNAT"

          accept
        }

        chain postrouting {
          type nat hook postrouting priority 0
          oifname ${wan0.name} masquerade
        }
      }

      table ip6 nat {
        chain prerouting {
          type nat hook prerouting priority 0

          iifname ${wan0.name} udp dport {
            ${ports.dns},
          } redirect to ${ports.wireguard} comment "router IPv6 WireGuard DNAT"

          accept
        }
      }
    '';
  };
}
