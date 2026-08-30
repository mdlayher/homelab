{ config, lib, ... }:

let
  inventory = config.homelab.inventory;

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
      EmitDNS = true;
      DNS = "_server_address";
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
  };

  # Drop-ins rendered from inventory secrets, keyed by networkd unit name.
  dropIns = {
    # We own the ULA /48, create a blanket unreachable route which will be
    # superseded by more specific /64s.
    "5-lo" = ''
      [Route]
      Destination=${inventory.ulaPrefix}::/48
      Type=unreachable
    '';
  }
  // lib.mapAttrs' (name: unit: lib.nameValuePair unit (lanDropIn inventory.interfaces.${name})) lans;
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

  # Use resolved for local DNS lookups, querying through CoreDNS.
  services.resolved = {
    enable = true;
    settings.Resolve = {
      Domains = [
        inventory.domain
        "taild07ab.ts.net"
      ];
      DNS = [
        "::1"
        "127.0.0.1"
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

    # Loopback. The ULA unreachable route comes from the inventory drop-in.
    networks."5-lo".matchConfig.Name = "lo";

    # Wired WAN: Spectrum 1GbE.
    links."10-wan0" = ethLink "wan0" "f4:90:ea:00:c7:8d";
    networks."10-wan0" = {
      matchConfig.Name = "wan0";
      networkConfig.DHCP = "yes";
      # Never accept ISP DNS or search domains for any DHCP/RA family.
      dhcpV4Config = {
        UseDNS = false;
        UseDomains = false;

        # Don't release IPv4 address on restart/reboots to avoid churn.
        SendRelease = false;

        # Deprioritize Spectrum IPv4.
        RouteMetric = 200;
      };
      dhcpV6Config = {
        # Spectrum gives a /56.
        PrefixDelegationHint = "::/56";

        UseDNS = false;
      };
      ipv6AcceptRAConfig = {
        UseDNS = false;
        UseDomains = false;
      };
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
      ];
    };

    # Physical management LAN. For physical LANs, we have to make sure to match
    # on both Type and MACAddress since VLANs would share the same MAC.
    links."15-mgmt0" = ethLink "mgmt0" "f4:90:ea:00:c7:8e";
    networks."15-mgmt0" = lanNetwork inventory.interfaces.mgmt0 // {
      # VLANs associated with this physical interface.
      vlan = [
        "lan0"
        "iot0"
        "guest0"
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
  };

  # Advertise routes to the Tailscale network.
  services.tailscale.useRoutingFeatures = "server";
}
