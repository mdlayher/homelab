{ config, lib, ... }:

let
  inventory = config.homelab.inventory;

  # An interconnect carrier is marked on its netdev (see interconnect.nix)
  # and caught here by a rule pointing at a table holding one WAN's default
  # route. That is what makes two carriers to one site independent: without
  # it both follow the main table out whichever WAN it prefers, and the IGP
  # forms two adjacencies over one path -- redundancy that reports healthy
  # and protects nothing.
  #
  # The tables hold a copy of each WAN's gateway rather than taking it away
  # from main, which still carries the defaults everything else on this
  # router uses. A WAN with one address family holds an unreachable default
  # for the other, so a marked packet of that family fails in its own table
  # rather than falling through to main and leaving by the other WAN, which
  # is the collapse onto one path the marks exist to prevent.
  wan0 = {
    mark = 1;
    table = 100;
  };
  wan1 = {
    mark = 2;
    table = 200;
  };

  # Rules sit with the WAN they steer to, so a WAN going away takes its rule
  # with it and the marked carrier fails rather than quietly falling back.
  markRule = wan: [
    {
      FirewallMark = wan.mark;
      Table = wan.table;
      Family = "both";
      Priority = 100;
    }
  ];

  ethLink = name: mac: {
    matchConfig = {
      Type = "ether";
      MACAddress = mac;
    };
    linkConfig = {
      Name = name;

      # Hardware tuning. Note that wan0/wan1/mgmt0 all happen to support a max
      # of 4096 since the NixOS option won't allow "max".
      RxBufferSize = 4096;
      TxBufferSize = 4096;
    };
  };

  vlanNetdev = name: id: {
    netdevConfig = {
      Name = name;
      Kind = "vlan";
    };
    vlanConfig.Id = id;
  };

  # Base configuration for a LAN interface the router serves. The router's
  # addresses and DHCP static leases are secrets from the inventory, rendered
  # into a drop-in by lanDropIn below.
  lanNetwork = ifi: {
    matchConfig.Name = ifi.name;
    address = [ "${ifi.lla}/64" ];
    networkConfig = {
      DHCPPrefixDelegation = true;
      DHCPServer = true;
      IPv6AcceptRA = false;
    };
    dhcpPrefixDelegationConfig = {
      # Router always lives at ::1.
      Token = "::1";
      # Delegate the associated hex subnet ID from DHCPv6-PD.
      SubnetId = lib.toLower (lib.toHexString ifi.vlan);
    };
    dhcpServerConfig = {
      DefaultLeaseTimeSec = 86400;
      MaxLeaseTimeSec = 86400;
      PoolOffset = 50;
      # The anycast resolver first, held by whichever node is nearest and
      # withdrawn with its service (see modules/anycast.nix), then this
      # interface's own router address, answered by the same process here
      # and kept as the address a client falls back to.
      EmitDNS = true;
      DNS = "${inventory.anycast4.dns} _server_address";

      # NTP on the same terms (see chrony.nix). _server_address is per
      # interface, so each LAN is told its own gateway: the only router
      # address a restricted LAN may talk to.
      EmitNTP = true;
      NTP = "${inventory.anycast4.ntp} _server_address";
    }
    # DNS search, as DHCP option 15: one domain, where the search list of
    # option 119 would need hand-encoding. So a client here learns its own
    # segment's namespace and no other. The RAs carry the full list (see
    # corerad.nix); this is what reaches clients that ignore them, and it
    # follows the same rule: a segment naming no host is told nothing.
    // lib.optionalAttrs (ifi.hosts != [ ]) {
      EmitDomain = true;
      Domain = ifi.searchDomain;
    };
  };

  # Drop-in for a LAN interface with the router's addresses and fixed leases.
  lanDropIn =
    ifi:
    ''
      [Network]
      Address=${ifi.ula}/64
      Address=${ifi.ipv4}/24
    ''
    + lib.concatMapStrings (host: ''

      [DHCPServerStaticLease]
      MACAddress=${host.mac}
      Address=${host.ipv4}
    '') ifi.hosts;

  # LAN interfaces and their networkd unit names.
  lans = {
    mgmt0 = "15-mgmt0";
    lan0 = "20-lan0";
    iot0 = "25-iot0";
    guest0 = "30-guest0";
    dev0 = "40-dev0";
  };

  # Drop-ins rendered from inventory secrets, keyed by networkd unit name.
  dropIns = lib.mapAttrs' (
    name: unit: lib.nameValuePair unit (lanDropIn inventory.interfaces.${name})
  ) lans;
in
{
  networking = {
    hostName = "routnerr-3";

    # Use systemd-networkd for configuration. Forcibly disable legacy DHCP
    # client.
    useNetworkd = true;
    useDHCP = false;

    # Use nftables instead.
    nat.enable = false;
    firewall.enable = false;
  };

  # A carrier whose mark nothing steers falls back to the main table, which
  # is the exact failure this arrangement exists to prevent and is invisible
  # once it happens: the adjacency comes up either way, over the wrong WAN.
  # Catch it at eval instead.
  assertions = [
    {
      assertion =
        let
          known = map (wan: wan.mark) [
            wan0
            wan1
          ];
          used = lib.filter (mark: mark != null) (
            lib.mapAttrsToList (_: link: link.firewallMark) config.homelab.interconnect.links
          );
        in
        lib.all (mark: lib.elem mark known) used;
      message = "every marked interconnect carrier needs a routing policy rule in networking.nix";
    }
  ];

  # Use resolved for local DNS lookups, querying the anycast resolver
  # address. While this machine's CoreDNS holds it the query never leaves
  # the machine; once withdrawn, the same address routes to whichever node
  # still answers, so a stopped resolver here costs this machine no names.
  services.resolved = {
    enable = true;
    settings.Resolve = {
      # Every namespace the router serves: it is on all of them, and it
      # resolves for itself rather than being handed a search list.
      Domains = [
        inventory.domain
      ]
      ++ map (ifi: ifi.searchDomain) (lib.attrValues inventory.interfaces);
      DNS = [
        inventory.anycast6.dns
        inventory.anycast4.dns
      ];
      DNSStubListener = false;
    };
  };

  # Render the inventory drop-ins at activation time and link each next to its
  # base unit.
  sops.templates = lib.mapAttrs' (
    unit: content:
    lib.nameValuePair "networkd-${unit}.conf" {
      inherit content;
      owner = "systemd-network";
      reloadUnits = [ "systemd-networkd.service" ];
    }
  ) dropIns;

  environment.etc = lib.mapAttrs' (
    unit: _:
    lib.nameValuePair "systemd/network/${unit}.network.d/inventory.conf" {
      source = config.sops.templates."networkd-${unit}.conf".path;
    }
  ) dropIns;

  # Manage network configuration with networkd.
  systemd.network = {
    enable = true;

    config.networkConfig.SpeedMeter = "yes";

    # Loopback. We own the ULA /48 and the IPv4 /8: a blanket unreachable
    # route for each, superseded by the more specific prefixes on each LAN
    # and by what the IGP learns from the other sites.
    networks."5-lo" = {
      matchConfig.Name = "lo";
      routes = [
        {
          Destination = inventory.ulaPrefix;
          Type = "unreachable";
        }
        {
          Destination = inventory.privatePrefix;
          Type = "unreachable";
        }
        {
          Destination = inventory.legacyPrefix;
          Type = "unreachable";
        }
      ];
    };

    # Wired WAN: Spectrum 1GbE.
    links."10-wan0" = ethLink "wan0" "f4:90:ea:00:c7:8d";
    networks."10-wan0" = {
      matchConfig.Name = "wan0";
      networkConfig.DHCP = "yes";
      # Never accept a service the ISP offers, in a lease or an
      # advertisement, for any family: the resolver and clock are our own
      # (see coredns.nix and chrony.nix). Addressing, routing and MTU are not.
      dhcpV4Config = {
        UseDNS = false;
        UseDNR = false;
        UseDomains = false;
        UseNTP = false;
        UseSIP = false;
        UseTimezone = false;
        UseCaptivePortal = false;

        # Don't release IPv4 address on restart/reboots to avoid churn.
        SendRelease = false;

        # Deprioritize Spectrum IPv4.
        RouteMetric = 200;
      };
      dhcpV6Config = {
        # Spectrum gives a /56.
        PrefixDelegationHint = "::/56";

        UseDNS = false;
        UseDNR = false;
        UseNTP = false;
        UseSIP = false;
        UseCaptivePortal = false;
      };
      ipv6AcceptRAConfig = {
        UseDNS = false;
        UseDNR = false;
        UseDomains = false;
        UseCaptivePortal = false;
      };

      # This is the only WAN with IPv6, so the carrier pinned here is the
      # one that can use it.
      routingPolicyRules = markRule wan0;
      routes = [
        {
          Gateway = "_dhcp4";
          Table = wan0.table;
        }
        {
          Gateway = "_ipv6ra";
          Table = wan0.table;
        }
      ];
    };

    # Wired WAN: Metronet 10GbE.
    links."11-wan1" = ethLink "wan1" "f4:90:ea:00:c7:91";
    networks."11-wan1" = {
      matchConfig.Name = "wan1";
      networkConfig.Address = "216.82.20.71/26";

      routes = [
        {
          Gateway = "216.82.20.65";

          # Prioritize Metronet IPv4.
          Metric = 100;
        }
        {
          Gateway = "216.82.20.65";
          Table = wan1.table;
        }
        # This WAN has no IPv6 at all. A carrier marked for it names an
        # IPv4-only endpoint, and should that name ever resolve to IPv6
        # the packet meets this rather than main's default out wan0.
        {
          Destination = "::/0";
          Type = "unreachable";
          Table = wan1.table;
        }
      ];

      routingPolicyRules = markRule wan1;
    };

    # Physical management LAN. For physical LANs, we have to make sure to match
    # on both Type and MACAddress since VLANs would share the same MAC.
    links."15-mgmt0" = ethLink "mgmt0" "f4:90:ea:00:c7:8e";
    networks."15-mgmt0" = lanNetwork inventory.interfaces.mgmt0 // {
      # VLANs associated with this physical interface. dn42i-dev0 is the
      # internal dn42 VLAN; it is defined in dn42.nix with the rest of the
      # dn42 presence, since its addressing is registry space rather than
      # anything from the inventory.
      vlan = [
        "lan0"
        "iot0"
        "guest0"
        "dev0"
      ]
      ++ map (vlan: vlan.interface) (lib.attrValues config.homelab.dn42.vlans);

      # The endpoint of the link to this site's other router
      # (interconnect.nix). Deprecated so nothing sources from it: it exists
      # for the GRETAP built on it, whose own packets carry addresses
      # configured on the netdev rather than chosen.
      addresses = [
        {
          Address = "${inventory.siteLinks.${config.homelab.site}.${config.networking.hostName}.carrier}/127";
          PreferredLifetime = "0";
        }
      ];
    };

    # Unused Ethernet and SFP+ links.
    links."15-eth2" = ethLink "eth2" "f4:90:ea:00:c7:8f";
    links."15-sfp0" = ethLink "sfp0" "f4:90:ea:00:c7:90";

    # Home VLAN.
    netdevs."20-lan0" = vlanNetdev "lan0" inventory.interfaces.lan0.vlan;
    networks."20-lan0" = lanNetwork inventory.interfaces.lan0;

    # IoT VLAN.
    netdevs."25-iot0" = vlanNetdev "iot0" inventory.interfaces.iot0.vlan;
    networks."25-iot0" = lanNetwork inventory.interfaces.iot0;

    # Guest VLAN.
    netdevs."30-guest0" = vlanNetdev "guest0" inventory.interfaces.guest0.vlan;
    networks."30-guest0" = lanNetwork inventory.interfaces.guest0;

    # Development VLAN.
    netdevs."40-dev0" = vlanNetdev "dev0" inventory.interfaces.dev0.vlan;
    networks."40-dev0" = lanNetwork inventory.interfaces.dev0;
  };

  # This machine is the tailnet's exit node, which the policy's
  # autoApprovers accepts without a console step. The flag is what
  # advertises it; useRoutingFeatures only turns on the forwarding sysctls
  # it needs, and a node advertising nothing still sets those happily.
  services.tailscale.useRoutingFeatures = "server";
  services.tailscale.extraSetFlags = [ "--advertise-exit-node" ];
}
