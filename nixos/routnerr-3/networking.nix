{ lib, ... }:

let
  unstable = import <nixos-unstable-small> { };
  vars = import ./lib/vars.nix;

  ethLink = (
    name:
    (mac: {
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
    })
  );

  vlanNetdev = (
    name:
    (id: {
      netdevConfig = {
        Name = name;
        Kind = "vlan";
      };
      vlanConfig.Id = id;
    })
  );

  vlanNetwork = (
    name:
    (id: {
      matchConfig.Name = name;
      # Embed ID directly in IPv4/6 addresses for clarity.
      address = [
        "fd9e:1a04:f01d:${toString id}::1/64"
        "fe80::1/64"
        "192.168.${toString id}.1/24"
      ];
      networkConfig = {
        DHCPPrefixDelegation = true;
        DHCPServer = true;
        IPv6AcceptRA = false;
      };
      dhcpPrefixDelegationConfig = {
        # Router always lives at ::1.
        Token = "::1";
        # Delegate the associated hex subnet ID from DHCPv6-PD.
        SubnetId = "${toString (decToHex id)}";
      };

      # DHCPServer on NixOS does not support Boot options yet.
      extraConfig = ''
        [DHCPServer]
        DefaultLeaseTimeSec = 86400
        MaxLeaseTimeSec = 86400
        PoolOffset = 50
        EmitDNS = true
        DNS = _server_address
        BootServerAddress = 192.168.${toString id}.1
        BootFilename = netboot.xyz.kpxe
      '';

      # Write out fixed leases per subnet.
      dhcpServerStaticLeases = lib.forEach vars.interfaces."${name}".hosts (host: {
        Address = host.ipv4;
        MACAddress = host.mac;
      });
    })
  );

  # Thanks, corpix!
  # https://gist.github.com/corpix/f761c82c9d6fdbc1b3846b37e1020e11
  decToHex =
    let
      intToHex = [
        "0"
        "1"
        "2"
        "3"
        "4"
        "5"
        "6"
        "7"
        "8"
        "9"
        "a"
        "b"
        "c"
        "d"
        "e"
        "f"
      ];
      toHex' = q: a: if q > 0 then (toHex' (q / 16) ((lib.elemAt intToHex (lib.mod q 16)) + a)) else a;
    in
    v: toHex' v "";
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
    domains = [
      vars.domain
      "taild07ab.ts.net"
    ];
    extraConfig = ''
      DNS=::1 127.0.0.1
      DNSStubListener=no
    '';
  };

  # Manage network configuration with networkd.
  systemd.network = {
    enable = true;

    config.networkConfig.SpeedMeter = "yes";

    # Loopback.
    networks."5-lo" = {
      matchConfig.Name = "lo";
      routes = [
        {
          # We own the ULA /48, create a blanket unreachable route which will be
          # superseded by more specific /64s.
          Destination = "fd9e:1a04:f01d::/48";
          Type = "unreachable";
        }
      ];
    };

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
    networks."15-mgmt0" = {
      matchConfig.Name = "mgmt0";

      # TODO(mdlayher): eventually it'd be nice to renumber this as
      # 192.168.0.1/24 but that would require a lot of device churn.
      address = [
        "fd9e:1a04:f01d::1/64"
        "fe80::1/64"
        "192.168.1.1/24"
      ];

      # VLANs associated with this physical interface.
      vlan = [
        "lan0"
        "iot0"
        "guest0"
        "lab0"
      ];

      networkConfig = {
        DHCPPrefixDelegation = true;
        DHCPServer = true;
        IPv6AcceptRA = false;
      };
      dhcpPrefixDelegationConfig = {
        Token = "::1";
        SubnetId = 0;
      };

      # DHCPServer on NixOS does not support Boot options yet.
      extraConfig = ''
        [DHCPServer]
        DefaultLeaseTimeSec = 86400
        MaxLeaseTimeSec = 86400
        PoolOffset = 50
        EmitDNS = true
        DNS = _server_address
        BootServerAddress = 192.168.1.1
        BootFilename = netboot.xyz.kpxe
      '';

      # Write out fixed leases per subnet.
      dhcpServerStaticLeases = lib.forEach vars.interfaces.mgmt0.hosts (host: {
        Address = host.ipv4;
        MACAddress = host.mac;
      });
    };

    # Unused Ethernet and SFP+ links.
    links."15-eth2" = ethLink "eth2" "f4:90:ea:00:c7:8f";
    links."15-sfp0" = ethLink "sfp0" "f4:90:ea:00:c7:90";

    # Home VLAN.
    netdevs."20-lan0" = vlanNetdev "lan0" 10;
    networks."20-lan0" = vlanNetwork "lan0" 10;

    # IoT VLAN.
    netdevs."25-iot0" = vlanNetdev "iot0" 66;
    networks."25-iot0" = vlanNetwork "iot0" 66;

    # Guest VLAN.
    netdevs."30-guest0" = vlanNetdev "guest0" 9;
    networks."30-guest0" = vlanNetwork "guest0" 9;

    # Lab VLAN.
    netdevs."35-lab0" = vlanNetdev "lab0" 2;
    networks."35-lab0" = vlanNetwork "lab0" 2;
  };

  services.tailscale = {
    enable = true;
    package = unstable.tailscale;
    interfaceName = "ts0";
    permitCertUid = "caddy";
    useRoutingFeatures = "server";
  };

  # Tailscale readiness and DNS tweaks.
  systemd.network.wait-online.ignoredInterfaces = [ "ts0" ];

  systemd.services.tailscaled = {
    after = [
      "network-online.target"
      "systemd-resolved.service"
    ];
    wants = [ "network-online.target" ];
  };
}
