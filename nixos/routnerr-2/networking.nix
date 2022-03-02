{ lib, ... }:

let
  vars = import ./lib/vars.nix;

  mkPeer = (peer: {
    publicKey = peer.public_key;
    allowedIPs = peer.allowed_ips;
  });

in {
  networking = {
    hostName = "routnerr-2";
    # TODO(mdlayher): systemd-resolved with fallback nameservers.
    nameservers = with vars.localhost; [ "${ipv4}" "${ipv6}" ];

    # Use systemd-networkd for configuration. Forcibly disable legacy DHCP
    # client.
    useNetworkd = true;
    useDHCP = false;

    wireguard = with vars.wireguard; {
      enable = true;
      interfaces = {
        ${name} = {
          listenPort = 51820;
          ips = with subnet; [
            "${ipv4}"
            "${ipv6.gua}"
            "${ipv6.ula}"
            "${ipv6.lla}"
          ];
          privateKeyFile = "/var/lib/wireguard/${name}.key";
          peers = lib.forEach peers mkPeer;
        };
      };
    };

    # Use nftables instead.
    nat.enable = false;
    firewall.enable = false;
  };

  # TODO(mdlayher): enable after working out CoreDNS dependency.
  services.resolved.enable = false;

  # Manage network configuration with networkd.
  #
  # TODO(mdlayher): template out again.
  systemd.network = {
    enable = true;

    # Wired WAN.
    links."10-wan0" = {
      matchConfig.MACAddress = "00:0d:b9:53:ea:cc";
      linkConfig.Name = "wan0";
    };
    networks."10-wan0" = {
      matchConfig.Name = "wan0";
      networkConfig.DHCP = "yes";
      # Never accept ISP DNS or search domains.
      dhcpV4Config = {
        UseDNS = false;
        UseDomains = false;
      };
      dhcpV6Config = {
        # Spectrum gives a /56.
        PrefixDelegationHint = "::/56";

        UseDNS = false;
        # TODO(mdlayher): NixOS doesn't allow this?
        # UseDomains = false;
      };
      ipv6AcceptRAConfig = {
        UseDNS = false;
        UseDomains = false;
      };
    };

    # TODO(mdlayher): wireless WAN.

    # Physical management LAN.
    links."11-mgmt0" = {
      # Important: match on Ethernet device type because VLANs share this MAC.
      matchConfig = {
        Type = "ether";
        MACAddress = "00:0d:b9:53:ea:cd";
      };
      linkConfig.Name = "mgmt0";
    };
    networks."11-mgmt0" = {
      matchConfig.Name = "mgmt0";
      address = [ "fd9e:1a04:f01d::1/64" "192.168.1.1/24" ];

      # VLANs associated with this physical interface.
      vlan = [ "lan0" "iot0" "guest0" "lab0" ];

      networkConfig.DHCPv6PrefixDelegation = true;
      dhcpV6PrefixDelegationConfig = {
        Token = "::1";
        SubnetId = 0;
      };
    };

    # Home VLAN.
    netdevs."12-lan0" = {
      netdevConfig = {
        Name = "lan0";
        Kind = "vlan";
      };
      vlanConfig.Id = 10;
    };
    networks."12-lan0" = {
      matchConfig.Name = "lan0";
      address = [ "fd9e:1a04:f01d:10::1/64" "192.168.10.1/24" ];
      networkConfig.DHCPv6PrefixDelegation = true;
      dhcpV6PrefixDelegationConfig = {
        Token = "::1";
        SubnetId = "a";
      };
    };

    # IoT VLAN.
    netdevs."13-iot0" = {
      netdevConfig = {
        Name = "iot0";
        Kind = "vlan";
      };
      vlanConfig.Id = 66;
    };
    networks."13-iot0" = {
      matchConfig.Name = "iot0";
      address = [ "fd9e:1a04:f01d:66::1/64" "192.168.66.1/24" ];
      networkConfig.DHCPv6PrefixDelegation = true;
      dhcpV6PrefixDelegationConfig = {
        Token = "::1";
        SubnetId = "42";
      };
    };

    # Guest VLAN.
    netdevs."14-guest0" = {
      netdevConfig = {
        Name = "guest0";
        Kind = "vlan";
      };
      vlanConfig.Id = 9;
    };
    networks."14-guest0" = {
      matchConfig.Name = "guest0";
      address = [ "fd9e:1a04:f01d:9::1/64" "192.168.9.1/24" ];
      networkConfig.DHCPv6PrefixDelegation = true;
      dhcpV6PrefixDelegationConfig = {
        Token = "::1";
        SubnetId = "9";
      };
    };

    # Lab VLAN.
    netdevs."15-lab0" = {
      netdevConfig = {
        Name = "lab0";
        Kind = "vlan";
      };
      vlanConfig.Id = 2;
    };
    networks."15-lab0" = {
      matchConfig.Name = "lab0";
      address = [ "fd9e:1a04:f01d:2::1/64" "192.168.2.1/24" ];
      networkConfig.DHCPv6PrefixDelegation = true;
      dhcpV6PrefixDelegationConfig = {
        Token = "::1";
        SubnetId = "2";
      };
    };
  };

  # Enable WireGuard Prometheus exporter and set up peer key/name mappings.
  # TODO: nixify the configuration.
  services.wireguard_exporter = {
    enable = true;
    config = ''
      ${lib.concatMapStrings (peer: ''
        [[peer]]
        public_key = "${peer.public_key}"
        name = "${peer.name}"
      '') vars.wireguard.peers}
    '';
  };
}
