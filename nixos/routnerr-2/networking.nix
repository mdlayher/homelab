{ lib, ... }:

let
  vars = import ./lib/vars.nix;

  # Produces the configuration for a LAN interface.
  mkInterface = (ifi: {
    ipv4.addresses = [{
      address = "${ifi.ipv4}";
      prefixLength = 24;
    }];
    ipv6.addresses = [
      {
        address = "${ifi.ipv6.lla}";
        prefixLength = 64;
      }
      {
        address = "${ifi.ipv6.ula}";
        prefixLength = 64;
      }
    ];
    tempAddress = "disabled";
  });

  mkPeer = (peer: {
    publicKey = peer.public_key;
    allowedIPs = peer.allowed_ips;
  });

in {
  # LAN interface.
  networking = {
    hostName = "routnerr-2";
    nameservers = with vars.localhost; [ "${ipv4}" "${ipv6}" ];

    dhcpcd = {
      enable = true;
      # Do not remove interface configuration on shutdown.
      persistent = true;
      allowInterfaces = [ "${vars.interfaces.wan0.name}" ];
      extraConfig = with vars.interfaces; ''
        noipv6rs
        interface ${wan0.name}
          ipv6rs
          # DHCPv6-PD.
          ia_na 0
          ia_pd 1/::/56 ${enp2s0.name}/0/64 ${lab0.name}/2/64 ${guest0.name}/9/64 ${lan0.name}/10/64 ${tengb0.name}/100/64 ${iot0.name}/102/64

          # IPv4 DHCP ISP settings overrides.
          static domain_name_servers=${vars.localhost.ipv4}
          static domain_search=
          static domain_name=
      '';
    };

    interfaces = with vars.interfaces; {
      ${enp2s0.name} = mkInterface enp2s0;
      ${lan0.name} = mkInterface lan0;
      ${lab0.name} = mkInterface lab0;
      ${guest0.name} = mkInterface guest0;
      ${iot0.name} = mkInterface iot0;
      ${tengb0.name} = mkInterface tengb0;
    };

    vlans = with vars.interfaces; {
      ${lab0.name} = {
        id = 2;
        interface = "${enp2s0.name}";
      };
      ${guest0.name} = {
        id = 9;
        interface = "${enp2s0.name}";
      };
      ${lan0.name} = {
        id = 10;
        interface = "${enp2s0.name}";
      };
      ${iot0.name} = {
        id = 66;
        interface = "${enp2s0.name}";
      };
      ${tengb0.name} = {
        id = 100;
        interface = "${enp2s0.name}";
      };
    };

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

    nat.enable = false;
    firewall.enable = false;
  };

  # Enable Prometheus exporter and set up peer key/name mappings.
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
