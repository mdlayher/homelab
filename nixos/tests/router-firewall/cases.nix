# The router firewall cases, run in order by run.sh. Each sends one probe
# from namespace `from` toward `dst`, and `to` names the namespace where an
# accepted probe arrives: a segment by its router interface, or router,
# internet, tailnet, remote, dn42peer, dn42host, far or unclassified (see
# the plan in default.nix).
#
# A probe is `tcp` or `udp` with a port, or `probe` naming ping, echo-hbh,
# mld or dhcp-discover (see packet.py). The verdict is `accept`, with the
# comment of the rule expected to count it where that rule has one, or
# `drop` or `reject` with the named counter expected to record it.
#
# A probe leaves from its namespace's own address (sources in default.nix)
# unless the case names another.
{ lib, f }:

let
  r = f.inv.interfaces;
  s = f.server;
  tv = f.hosts.${lib.head f.lgtv.hosts};
  deployer = f.hosts.linuxdev;
  forwards = map (fw: f.hosts.${fw.host} // { inherit (fw) port; }) f.inv.tailscaleForwards;
  fwd = lib.head forwards;
  reach = lib.head f.remote.device.reaches;
  reachHost = f.hosts.${reach.target};

  client4 = name: "${r.${name}.ipv4Prefix}.10";
  client6 = name: "${r.${name}.ulaPrefix}::10";

  case =
    name: a:
    let
      probe =
        if a ? tcp then
          {
            probe = "tcp";
            port = a.tcp;
          }
        else if a ? udp then
          {
            probe = "udp";
            port = a.udp;
          }
        else
          { port = a.port or null; };
      verdict =
        if a ? accept then
          {
            verdict = "accept";
            what = if a.accept == true then null else a.accept;
          }
        else if a ? drop then
          {
            verdict = "drop";
            what = a.drop;
          }
        else
          {
            verdict = "reject";
            what = a.reject;
          };
      src =
        if a ? src then
          a.src
        else if lib.hasInfix ":" a.dst then
          f.sources.${a.from}.v6
        else
          f.sources.${a.from}.v4 or null;
    in
    {
      inherit name src;
      inherit (a) from to dst;
      sport = a.sport or null;
    }
    // removeAttrs a [
      "tcp"
      "udp"
      "accept"
      "drop"
      "reject"
      "src"
    ]
    // probe
    // verdict;
in
assert lib.assertMsg
  (!lib.any (x: x.target == lib.head f.inv.roles.server && x.port == 22) f.remote.device.reaches)
  "router-firewall: the remote access refusal case needs the server's SSH outside the device's reaches";
[
  # Restricted LANs.

  # forward: "restricted LANs to LANs"
  (case "restricted to trusted host v4" {
    from = "guest0";
    to = s.interface;
    dst = s.ipv4;
    tcp = 22;
    drop = "restricted_forward_drop";
  })
  (case "restricted to trusted host v6" {
    from = "guest0";
    to = s.interface;
    dst = s.ula;
    tcp = 22;
    drop = "restricted_forward_drop";
  })
  (case "restricted to restricted" {
    from = "guest0";
    to = "iot0";
    dst = client4 "iot0";
    tcp = 80;
    drop = "restricted_forward_drop";
  })
  # forward: "restricted LANs only to WANs"
  (case "restricted to WAN v4" {
    from = "guest0";
    to = "internet";
    dst = f.net.wan0.peer4;
    tcp = 443;
    accept = "restricted LANs only to WANs";
  })
  (case "restricted to WAN v6" {
    from = "guest0";
    to = "internet";
    dst = f.net.wan0.peer6;
    tcp = 443;
    accept = "restricted LANs only to WANs";
  })
  # input_restricted: "router restricted TCP", "router restricted UDP",
  # "router restricted NTP"
  (case "restricted to own router DNS TCP v4" {
    from = "guest0";
    to = "router";
    dst = r.guest0.ipv4;
    tcp = 53;
    accept = "router restricted TCP";
  })
  (case "restricted to own router DNS UDP v4" {
    from = "guest0";
    to = "router";
    dst = r.guest0.ipv4;
    udp = 53;
    accept = "router restricted UDP";
  })
  (case "restricted to own router NTP v4" {
    from = "guest0";
    to = "router";
    dst = r.guest0.ipv4;
    udp = 123;
    accept = "router restricted NTP";
  })
  (case "restricted to own router DNS TCP v6" {
    from = "guest0";
    to = "router";
    dst = r.guest0.ula;
    tcp = 53;
    accept = "router restricted TCP";
  })
  (case "restricted to own router DNS UDP v6" {
    from = "guest0";
    to = "router";
    dst = r.guest0.ula;
    udp = 53;
    accept = "router restricted UDP";
  })
  (case "restricted to own router NTP v6" {
    from = "guest0";
    to = "router";
    dst = r.guest0.ula;
    udp = 123;
    accept = "router restricted NTP";
  })
  # input_restricted: the final drop
  (case "restricted to own router SSH" {
    from = "guest0";
    to = "router";
    dst = r.guest0.ipv4;
    tcp = 22;
    drop = "restricted_input_drop";
  })
  # input_restricted: "traffic leaving IPv4 VLAN", "traffic leaving IPv6 VLAN"
  (case "restricted to router on another VLAN v4" {
    from = "guest0";
    to = "router";
    dst = r.dev0.ipv4;
    udp = 53;
    drop = "restricted_crossvlan_drop";
  })
  (case "restricted to router on another VLAN v6" {
    from = "guest0";
    to = "router";
    dst = r.dev0.ula;
    udp = 53;
    drop = "restricted_crossvlan_drop";
  })
  # input_restricted: "router restricted anycast DNS", "router restricted
  # anycast NTP"
  (case "restricted to anycast DNS v4" {
    from = "guest0";
    to = "router";
    dst = f.inv.anycast4.dns;
    udp = 53;
    accept = "router restricted anycast DNS";
  })
  (case "restricted to anycast NTP v4" {
    from = "guest0";
    to = "router";
    dst = f.inv.anycast4.ntp;
    udp = 123;
    accept = "router restricted anycast NTP";
  })
  (case "restricted to anycast DNS v6" {
    from = "guest0";
    to = "router";
    dst = f.inv.anycast6.dns;
    tcp = 53;
    accept = "router restricted anycast DNS";
  })
  (case "restricted to anycast NTP v6" {
    from = "guest0";
    to = "router";
    dst = f.inv.anycast6.ntp;
    udp = 123;
    accept = "router restricted anycast NTP";
  })
  # services_wan, through input_restricted's local destination jump:
  # "router WAN Tailscale"
  (case "restricted to router WAN Tailscale" {
    from = "guest0";
    to = "router";
    dst = f.net.wan0.router4;
    udp = 41641;
    accept = "router WAN Tailscale";
  })
  # forward: "restricted LANs to LANs", the tailnet being trusted
  (case "restricted to tailnet host" {
    from = "guest0";
    to = "tailnet";
    dst = f.net.ts0.peer4;
    tcp = 22;
    drop = "restricted_forward_drop";
  })

  # Restricted LAN multicast and broadcast.

  # input_restricted: "router restricted DHCPv4"
  (case "restricted DHCPv4 discover" {
    from = "guest0";
    to = "router";
    dst = "255.255.255.255";
    probe = "dhcp-discover";
    port = 67;
    accept = "router restricted DHCPv4";
  })
  # input_restricted: "router iot0 mDNS reflection"
  (case "iot0 mDNS v4" {
    from = "iot0";
    to = "router";
    dst = "224.0.0.251";
    udp = 5353;
    sport = 5353;
    accept = "router iot0 mDNS reflection";
  })
  (case "iot0 mDNS v6" {
    from = "iot0";
    to = "router";
    dst = "ff02::fb";
    udp = 5353;
    sport = 5353;
    accept = "router iot0 mDNS reflection";
  })
  # input_restricted: "restricted LAN multicast"
  (case "restricted SSDP v4" {
    from = "guest0";
    to = "router";
    dst = "239.255.255.250";
    udp = 1900;
    drop = "restricted_multicast_drop";
  })
  (case "restricted SSDP v6" {
    from = "guest0";
    to = "router";
    dst = "ff02::c";
    udp = 1900;
    drop = "restricted_multicast_drop";
  })
  (case "restricted mDNS" {
    from = "guest0";
    to = "router";
    dst = "224.0.0.251";
    udp = 5353;
    sport = 5353;
    drop = "restricted_multicast_drop";
  })
  (case "restricted MLD report" {
    from = "guest0";
    to = "router";
    dst = "ff02::fb";
    probe = "mld";
    drop = "restricted_multicast_drop";
  })

  # ICMP from LANs.

  # icmp_lan, from input
  (case "restricted ping own router v4" {
    from = "guest0";
    to = "router";
    dst = r.guest0.ipv4;
    probe = "ping";
    accept = true;
  })
  (case "restricted ping own router v6" {
    from = "guest0";
    to = "router";
    dst = r.guest0.ula;
    probe = "ping";
    accept = true;
  })
  (case "restricted echo behind hop-by-hop header" {
    from = "guest0";
    to = "router";
    dst = r.guest0.ula;
    probe = "echo-hbh";
    accept = true;
  })
  # icmp_lan, from forward's debug segment jump
  (case "debug segment ping restricted v4" {
    from = "dev0";
    to = "guest0";
    dst = client4 "guest0";
    probe = "ping";
    accept = true;
  })
  (case "debug segment ping restricted v6" {
    from = "dev0";
    to = "guest0";
    dst = client6 "guest0";
    probe = "ping";
    accept = true;
  })
  # forward: "restricted LANs to LANs", ahead of icmp_lan
  (case "restricted ping debug segment" {
    from = "guest0";
    to = "dev0";
    dst = client4 "dev0";
    probe = "ping";
    drop = "restricted_forward_drop";
  })

  # Deploys and the TVs' syslog.

  # forward: "deploy"
  (case "deploy SSH v4" {
    from = deployer.interface;
    to = tv.interface;
    src = deployer.ipv4;
    dst = tv.ipv4;
    tcp = 22;
    accept = "deploy";
  })
  (case "deploy Glasshouse v4" {
    from = deployer.interface;
    to = tv.interface;
    src = deployer.ipv4;
    dst = tv.ipv4;
    tcp = f.lgtv.port;
    accept = "deploy";
  })
  (case "deploy SSH v6" {
    from = deployer.interface;
    to = tv.interface;
    src = deployer.ula;
    dst = tv.ula;
    tcp = 22;
    accept = "deploy";
  })
  # forward: "restricted LANs to LANs"
  (case "deploy port from another address v4" {
    from = deployer.interface;
    to = tv.interface;
    dst = tv.ipv4;
    tcp = 22;
    drop = "restricted_forward_drop";
  })
  (case "deploy port from another address v6" {
    from = deployer.interface;
    to = tv.interface;
    dst = tv.ula;
    tcp = f.lgtv.port;
    drop = "restricted_forward_drop";
  })
  # forward: "LG TV syslog"
  (case "TV syslog v4" {
    from = tv.interface;
    to = s.interface;
    src = tv.ipv4;
    dst = s.ipv4;
    udp = f.lgtv.syslogPort;
    accept = "LG TV syslog";
  })
  (case "TV syslog v6" {
    from = tv.interface;
    to = s.interface;
    src = tv.ula;
    dst = s.ula;
    udp = f.lgtv.syslogPort;
    accept = "LG TV syslog";
  })
  # forward: "restricted LANs to LANs"
  (case "TV to server SSH" {
    from = tv.interface;
    to = s.interface;
    src = tv.ipv4;
    dst = s.ipv4;
    tcp = 22;
    drop = "restricted_forward_drop";
  })

  # Spoofed sources and hosts denied the internet.

  # prerouting: "spoofed source"
  (case "trusted LAN with another segment's source v4" {
    from = "lan0";
    to = "internet";
    src = client4 "dev0";
    dst = f.net.wan0.peer4;
    tcp = 443;
    drop = "spoofed_drop";
  })
  (case "trusted LAN with another segment's source v6" {
    from = "lan0";
    to = "internet";
    src = client6 "dev0";
    dst = f.net.wan0.peer6;
    tcp = 443;
    drop = "spoofed_drop";
  })
  (case "restricted LAN with a trusted host's source" {
    from = "guest0";
    to = "internet";
    src = client4 s.interface;
    dst = f.net.wan0.peer4;
    tcp = 443;
    drop = "spoofed_drop";
  })
  # forward: "hosts denied the internet"
  (case "denied MAC to WAN" {
    from = f.denied.ifname;
    to = "internet";
    src = f.denied.ipv4;
    dst = f.net.wan0.peer4;
    probe = "ping";
    drop = "wan_denied_drop";
  })

  # Trusted LANs and the tailnet.

  # forward: "trusted LANs to all WANs"
  (case "trusted to WAN v4" {
    from = "lan0";
    to = "internet";
    dst = f.net.wan0.peer4;
    tcp = 443;
    accept = "trusted LANs to all WANs";
  })
  (case "trusted to WAN v6" {
    from = "lan0";
    to = "internet";
    dst = f.net.wan0.peer6;
    tcp = 443;
    accept = "trusted LANs to all WANs";
  })
  # forward: "trusted LANs to all LANs"
  (case "trusted to restricted" {
    from = "lan0";
    to = "guest0";
    dst = client4 "guest0";
    tcp = 22;
    accept = "trusted LANs to all LANs";
  })
  (case "trusted to trusted" {
    from = "lan0";
    to = s.interface;
    dst = s.ula;
    tcp = 22;
    accept = "trusted LANs to all LANs";
  })
  (case "tailnet to LAN" {
    from = "tailnet";
    to = s.interface;
    dst = s.ipv4;
    tcp = 22;
    accept = "trusted LANs to all LANs";
  })
  # input: "localhost and trusted LANs to router"
  (case "trusted to router SSH" {
    from = "lan0";
    to = "router";
    dst = r.lan0.ipv4;
    tcp = 22;
    accept = "localhost and trusted LANs to router";
  })

  # The internet.

  # input_wan: the final drop
  (case "WAN to router SSH v4" {
    from = "internet";
    to = "router";
    dst = f.net.wan0.router4;
    tcp = 22;
    drop = "wan_input_drop";
  })
  (case "WAN to router SSH v6" {
    from = "internet";
    to = "router";
    dst = f.net.wan0.router6;
    tcp = 22;
    drop = "wan_input_drop";
  })
  # services_wan: "router WAN Tailscale"
  (case "WAN to router Tailscale" {
    from = "internet";
    to = "router";
    dst = f.net.wan0.router4;
    udp = 41641;
    accept = "router WAN Tailscale";
  })
  # input_wan: "router WAN ping"
  (case "WAN ping router v4" {
    from = "internet";
    to = "router";
    dst = f.net.wan0.router4;
    probe = "ping";
    accept = "router WAN ping";
  })
  (case "WAN ping router v6" {
    from = "internet";
    to = "router";
    dst = f.net.wan0.router6;
    probe = "ping";
    accept = "router WAN ping";
  })
  # forward_wan: the final drop
  (case "WAN to LAN host v4" {
    from = "internet";
    to = s.interface;
    dst = s.ipv4;
    tcp = 22;
    drop = "wan_forward_drop";
  })
  (case "WAN to LAN host v6" {
    from = "internet";
    to = s.interface;
    dst = s.ula;
    tcp = 22;
    drop = "wan_forward_drop";
  })
  # nat prerouting: "Tailscale UDPv4 DNAT", then forward_wan: "Tailscale
  # IPv4 forwarding"
  (case "WAN Tailscale forward v4" {
    from = "internet";
    to = fwd.interface;
    dst = f.net.wan0.router4;
    udp = fwd.port;
    accept = "Tailscale IPv4 forwarding";
  })
  # forward_wan: "Tailscale IPv6 forwarding"
  (case "WAN Tailscale forward v6" {
    from = "internet";
    to = fwd.interface;
    dst = fwd.ula;
    udp = fwd.port;
    accept = "Tailscale IPv6 forwarding";
  })
]
++ lib.optional (lib.length forwards > 1) (
  # forward_wan: the final drop, for a forward port aimed at another host
  case "WAN Tailscale port of another host v6" {
    from = "internet";
    to = fwd.interface;
    dst = fwd.ula;
    udp = (lib.elemAt forwards 1).port;
    drop = "wan_forward_drop";
  }
)
++ [
  # External dn42 peers.

  # input_dn42e: "router dn42 external BGP"
  (case "dn42 peer to router BGP v4" {
    from = "dn42peer";
    to = "router";
    dst = f.dn42.addr4;
    tcp = 179;
    accept = "router dn42 external BGP";
  })
  (case "dn42 peer to router BGP v6" {
    from = "dn42peer";
    to = "router";
    dst = f.dn42.addr6;
    tcp = 179;
    accept = "router dn42 external BGP";
  })
  # icmp_lan, from input_dn42e
  (case "dn42 peer echo behind hop-by-hop header" {
    from = "dn42peer";
    to = "router";
    dst = f.dn42.addr6;
    probe = "echo-hbh";
    accept = true;
  })
  # input_dn42e: "non-dn42 source"
  (case "dn42 peer with a site source to router v4" {
    from = "dn42peer";
    to = "router";
    src = s.ipv4;
    dst = f.dn42.addr4;
    tcp = 179;
    drop = "dn42_input_drop";
  })
  # input: "our own source from dn42"
  (case "dn42 peer with a site source to router v6" {
    from = "dn42peer";
    to = "router";
    src = s.ula;
    dst = f.dn42.addr6;
    tcp = 179;
    drop = "dn42_input_drop";
  })
  (case "dn42 peer with our dn42 source to router v4" {
    from = "dn42peer";
    to = "router";
    src = f.ourDn42.v4;
    dst = f.dn42.addr4;
    tcp = 179;
    drop = "dn42_input_drop";
  })
  (case "dn42 peer with our dn42 source to router v6" {
    from = "dn42peer";
    to = "router";
    src = f.ourDn42.v6;
    dst = f.dn42.addr6;
    tcp = 179;
    drop = "dn42_input_drop";
  })
  # forward: "dn42 to LANs and WANs"
  (case "dn42 peer to LAN host" {
    from = "dn42peer";
    to = "lan0";
    dst = client6 "lan0";
    tcp = 22;
    drop = "dn42_forward_drop";
  })
  # forward: "dn42 to another site"
  (case "dn42 peer to far site v4" {
    from = "dn42peer";
    to = "far";
    dst = f.far.host4;
    tcp = 22;
    drop = "dn42_forward_drop";
  })
  (case "dn42 peer to far site v6" {
    from = "dn42peer";
    to = "far";
    dst = f.far.host6;
    tcp = 22;
    drop = "dn42_forward_drop";
  })
  # forward: "dn42 transit to interconnect"
  (case "dn42 transit to a circuit v4" {
    from = "dn42peer";
    to = "far";
    dst = f.far.dn42v4;
    tcp = 179;
    accept = "dn42 transit to interconnect";
  })
  (case "dn42 transit to a circuit v6" {
    from = "dn42peer";
    to = "far";
    dst = f.far.dn42v6;
    tcp = 179;
    accept = "dn42 transit to interconnect";
  })
  # forward: "our own source from dn42"
  (case "dn42 peer with the router's dn42 loopback toward a circuit" {
    from = "dn42peer";
    to = "far";
    src = f.dn42.loopback6;
    dst = f.far.dn42v6;
    tcp = 179;
    drop = "dn42_forward_drop";
  })
  (case "dn42 peer with our dn42 source toward a circuit" {
    from = "dn42peer";
    to = "far";
    src = f.ourDn42.v4;
    dst = f.far.dn42v4;
    tcp = 179;
    drop = "dn42_forward_drop";
  })
  (case "dn42 peer with the server's source toward a circuit v4" {
    from = "dn42peer";
    to = "far";
    src = s.ipv4;
    dst = f.far.dn42v4;
    tcp = 179;
    drop = "dn42_forward_drop";
  })
  (case "dn42 peer with the server's source toward a circuit v6" {
    from = "dn42peer";
    to = "far";
    src = s.ula;
    dst = f.far.dn42v6;
    tcp = 179;
    drop = "dn42_forward_drop";
  })
  # forward: "dn42 to LANs and WANs", the transit accept requiring a dn42
  # source
  (case "dn42 peer with a non-dn42 source toward a circuit v4" {
    from = "dn42peer";
    to = "far";
    src = f.net.foreign4;
    dst = f.far.dn42v4;
    tcp = 179;
    drop = "dn42_forward_drop";
  })
  (case "dn42 peer with a non-dn42 source toward a circuit v6" {
    from = "dn42peer";
    to = "far";
    src = f.net.foreign6;
    dst = f.far.dn42v6;
    tcp = 179;
    drop = "dn42_forward_drop";
  })
  # forward: "dn42 transit via interconnect"
  (case "dn42 transit from a circuit v4" {
    from = "far";
    to = "dn42peer";
    src = f.far.dn42v4;
    dst = f.peer.ipv4;
    tcp = 80;
    accept = "dn42 transit via interconnect";
  })
  (case "dn42 transit from a circuit v6" {
    from = "far";
    to = "dn42peer";
    src = f.far.dn42v6;
    dst = f.peer.ipv6;
    tcp = 80;
    accept = "dn42 transit via interconnect";
  })
  # forward: "another site to dn42"
  (case "site source from a circuit to a dn42 peer v4" {
    from = "far";
    to = "dn42peer";
    src = f.far.host4;
    dst = f.peer.ipv4;
    tcp = 80;
    drop = "dn42_forward_drop";
  })
  (case "site source from a circuit to a dn42 peer v6" {
    from = "far";
    to = "dn42peer";
    src = f.far.host6;
    dst = f.peer.ipv6;
    tcp = 80;
    drop = "dn42_forward_drop";
  })

  # Our own dn42 hosts.

  # forward: "dn42 internal to external"
  (case "dn42 host to peer v4" {
    from = "dn42host";
    to = "dn42peer";
    dst = f.peer.ipv4;
    tcp = 80;
    accept = "dn42 internal to external";
  })
  (case "dn42 host to peer v6" {
    from = "dn42host";
    to = "dn42peer";
    dst = f.peer.ipv6;
    tcp = 80;
    accept = "dn42 internal to external";
  })
  # forward_dn42i: the final drop
  (case "dn42 peer to dn42 host" {
    from = "dn42peer";
    to = "dn42host";
    dst = f.dn42Host.ipv6;
    tcp = 22;
    drop = "dn42_inbound_drop";
  })

  # The site interconnect.

  # forward_icl: "site services from a circuit"
  (case "far site to a site service" {
    from = "far";
    to = s.interface;
    src = f.far.host6;
    dst = s.ula;
    tcp = f.lokiPort;
    accept = "site services from a circuit";
  })
  # forward_icl: the final drop
  (case "far site to a LAN host" {
    from = "far";
    to = s.interface;
    src = f.far.host6;
    dst = s.ula;
    tcp = 22;
    drop = "icl_forward_drop";
  })
  # input_icl: "router interconnect BGP"
  (case "far site to router BGP" {
    from = "far";
    to = "router";
    src = f.far.lo6;
    dst = f.inv.loopbacks.${lib.head f.inv.roles.router}.addr6;
    tcp = 179;
    accept = "router interconnect BGP";
  })
  # forward: "interconnect site out"
  (case "trusted to far site" {
    from = "lan0";
    to = "far";
    dst = f.far.host6;
    tcp = 22;
    accept = "interconnect site out";
  })
  # forward: "restricted LANs to another site"
  (case "restricted to far site" {
    from = "guest0";
    to = "far";
    dst = f.far.host6;
    tcp = 22;
    drop = "restricted_forward_drop";
  })

  # The remote access tunnel.

  # forward_remote: "remote access device reaches"
  (case "remote device to a host it reaches" {
    from = "remote";
    to = reachHost.interface;
    dst = reachHost.ula;
    ${reach.protocol} = reach.port;
    accept = "remote access device reaches";
  })
  # forward_remote: the final drop
  (case "remote device to a host it does not reach" {
    from = "remote";
    to = s.interface;
    dst = s.ula;
    tcp = 22;
    drop = "remote_forward_drop";
  })
  # input: "remote access anycast DNS"
  (case "remote device to anycast DNS" {
    from = "remote";
    to = "router";
    dst = f.inv.anycast6.dns;
    udp = 53;
    accept = "remote access anycast DNS";
  })

  # Anything else.

  # input: the final reject
  (case "unclassified interface to router" {
    from = "unclassified";
    to = "router";
    dst = f.net.unclassified.router4;
    tcp = 22;
    reject = "input_reject";
  })
]
