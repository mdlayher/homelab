{ lib, ... }:

let
  vars = import ./lib/vars.nix;

in {
  networking = {
    hostName = "routnerr-2";

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
    domains = [ vars.domain ];
    extraConfig = ''
      DNS=::1 127.0.0.1
      DNSStubListener=no
    '';
  };

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
      # Never accept ISP DNS or search domains for any DHCP/RA family.
      dhcpV4Config = {
        UseDNS = false;
        UseDomains = false;

        # Don't release IPv4 address on restart/reboots to avoid churn.
        SendRelease = false;
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

    # Wireless WAN.
    links."11-wwan0" = {
      matchConfig.Path = "pci-0000:00:13.0-usb-0:1.3:1.12";
      linkConfig.Name = "wwan0";
    };
    networks."11-wwan0" = {
      # Disabled; waiting on networkd + ModemManager integration.
      enable = false;

      matchConfig.Name = "wwan0";
      networkConfig = {
        DHCP = "yes";
        DefaultRouteOnDevice = false;
      };
      # Do not require WWAN for online.
      linkConfig.RequiredForOnline = false;
      # Never accept ISP DNS or search domains.
      dhcpV4Config = {
        UseDNS = false;
        UseDomains = false;
      };
      dhcpV6Config = {
        UseDNS = false;
        # TODO(mdlayher): NixOS doesn't allow this?
        # UseDomains = false;
      };
      ipv6AcceptRAConfig = {
        UseDNS = false;
        UseDomains = false;
      };
    };

    # Physical management LAN.
    links."15-mgmt0" = {
      # Important: match on Ethernet device type because VLANs share this MAC.
      matchConfig = {
        Type = "ether";
        MACAddress = "00:0d:b9:53:ea:cd";
      };
      linkConfig.Name = "mgmt0";
    };
    networks."15-mgmt0" = {
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
    netdevs."20-lan0" = {
      netdevConfig = {
        Name = "lan0";
        Kind = "vlan";
      };
      vlanConfig.Id = 10;
    };
    networks."20-lan0" = {
      matchConfig.Name = "lan0";
      address = [ "fd9e:1a04:f01d:10::1/64" "192.168.10.1/24" ];
      networkConfig.DHCPv6PrefixDelegation = true;
      dhcpV6PrefixDelegationConfig = {
        Token = "::1";
        SubnetId = "a";
      };
    };

    # IoT VLAN.
    netdevs."25-iot0" = {
      netdevConfig = {
        Name = "iot0";
        Kind = "vlan";
      };
      vlanConfig.Id = 66;
    };
    networks."25-iot0" = {
      matchConfig.Name = "iot0";
      address = [ "fd9e:1a04:f01d:66::1/64" "192.168.66.1/24" ];
      networkConfig.DHCPv6PrefixDelegation = true;
      dhcpV6PrefixDelegationConfig = {
        Token = "::1";
        SubnetId = "42";
      };
    };

    # Guest VLAN.
    netdevs."30-guest0" = {
      netdevConfig = {
        Name = "guest0";
        Kind = "vlan";
      };
      vlanConfig.Id = 9;
    };
    networks."30-guest0" = {
      matchConfig.Name = "guest0";
      address = [ "fd9e:1a04:f01d:9::1/64" "192.168.9.1/24" ];
      networkConfig.DHCPv6PrefixDelegation = true;
      dhcpV6PrefixDelegationConfig = {
        Token = "::1";
        SubnetId = "9";
      };
    };

    # Lab VLAN.
    netdevs."35-lab0" = {
      netdevConfig = {
        Name = "lab0";
        Kind = "vlan";
      };
      vlanConfig.Id = 2;
    };
    networks."35-lab0" = {
      matchConfig.Name = "lab0";
      address = [ "fd9e:1a04:f01d:2::1/64" "192.168.2.1/24" ];
      networkConfig.DHCPv6PrefixDelegation = true;
      dhcpV6PrefixDelegationConfig = {
        Token = "::1";
        SubnetId = "2";
      };
    };

    # WireGuard tunnel.
    netdevs."40-wg0" = {
      netdevConfig = {
        Name = "wg0";
        Kind = "wireguard";
      };
      wireguardConfig = {
        PrivateKeyFile = "/var/lib/wireguard/wg0.key";
        ListenPort = 51820;
      };
      wireguardPeers = lib.forEach vars.wireguard.peers (peer: {
        wireguardPeerConfig = {
          PublicKey = peer.public_key;
          AllowedIPs = peer.allowed_ips;
        };
      });
    };
    networks."40-wg0" = {
      matchConfig.Name = "wg0";
      address = with vars.wireguard.subnet; [ ipv4 ipv6.gua ipv6.ula ipv6.lla ];
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
