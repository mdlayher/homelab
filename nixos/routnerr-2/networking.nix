{ lib, ... }:

let
  vars = import ./lib/vars.nix;

  ethLink = (name:
    (mac: {
      matchConfig = {
        Type = "ether";
        MACAddress = mac;
      };
      linkConfig.Name = name;
    }));

  vlanNetdev = (name:
    (id: {
      netdevConfig = {
        Name = name;
        Kind = "vlan";
      };
      vlanConfig.Id = id;
    }));

  vlanNetwork = (name:
    (id: {
      matchConfig.Name = name;
      # Embed ID directly in IPv4/6 addresses for clarity.
      address =
        [ "fd9e:1a04:f01d:${toString id}::1/64" "192.168.${toString id}.1/24" ];
      networkConfig.DHCPv6PrefixDelegation = true;
      dhcpV6PrefixDelegationConfig = {
        # Router always lives at ::1.
        Token = "::1";
        # Delegate the associated hex subnet ID from DHCPv6-PD.
        SubnetId = "${toString (decToHex id)}";
      };
    }));

  # Thanks, corpix!
  # https://gist.github.com/corpix/f761c82c9d6fdbc1b3846b37e1020e11
  decToHex = let
    intToHex =
      [ "0" "1" "2" "3" "4" "5" "6" "7" "8" "9" "a" "b" "c" "d" "e" "f" ];
    toHex' = q: a:
      if q > 0 then
        (toHex' (q / 16) ((lib.elemAt intToHex (lib.mod q 16)) + a))
      else
        a;
  in v: toHex' v "";
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
    links."10-wan0" = ethLink "wan0" "00:0d:b9:53:ea:cc";
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

    # Wireless WAN, temporarily unused.
    links."11-wwan0" = {
      matchConfig.Path = "pci-0000:00:13.0-usb-0:1.3:1.12";
      linkConfig.Name = "wwan0";
    };

    # Physical management LAN. For physical LANs, we have to make sure to match
    # on both Type and MACAddress since VLANs would share the same MAC.
    links."15-mgmt0" = ethLink "mgmt0" "00:0d:b9:53:ea:cd";
    networks."15-mgmt0" = {
      matchConfig.Name = "mgmt0";

      # TODO(mdlayher): eventually it'd be nice to renumber this as
      # 192.168.0.1/24 but that would require a lot of device churn.
      address = [ "fd9e:1a04:f01d::1/64" "192.168.1.1/24" ];

      # VLANs associated with this physical interface.
      vlan = [ "lan0" "iot0" "guest0" "lab0" ];

      networkConfig.DHCPv6PrefixDelegation = true;
      dhcpV6PrefixDelegationConfig = {
        Token = "::1";
        SubnetId = 0;
      };
    };

    # Unused physical management LANs.
    links."16-mgmt1" = ethLink "mgmt1" "00:0d:b9:53:ea:ce";
    links."17-mgmt2" = ethLink "mgmt2" "00:0d:b9:53:ea:cf";

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
