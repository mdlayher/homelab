{ ... }:

let
  vars = import ./vars.nix;

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
          ia_pd 1/::/56 ${lan0.name}/0/64 ${lab0.name}/2/64 ${guest0.name}/9/64 ${iot0.name}/102/64

          # IPv4 DHCP ISP settings overrides.
          static domain_name_servers=${vars.localhost.ipv4}
          static domain_search=
          static domain_name=
      '';
    };

    interfaces = with vars.interfaces; {
      ${lan0.name} = mkInterface lan0;
      ${lab0.name} = mkInterface lab0;
      ${guest0.name} = mkInterface guest0;
      ${iot0.name} = mkInterface iot0;
    };

    vlans = with vars.interfaces; {
      ${lab0.name} = {
        id = 2;
        interface = "${lan0.name}";
      };
      ${guest0.name} = {
        id = 9;
        interface = "${lan0.name}";
      };
      ${iot0.name} = {
        id = 66;
        interface = "${lan0.name}";
      };
    };

    wireguard = with vars.interfaces.wg0; {
      enable = true;
      interfaces = {
        ${name} = {
          listenPort = 51820;
          ips =
            [ "${ipv4}/24" "${ipv6.gua}/64" "${ipv6.ula}/64" "${ipv6.lla}/64" ];
          privateKeyFile = "/var/lib/wireguard/${name}.key";
          peers = [
            # mdlayher-fastly
            {
              publicKey = "VWRsPtbdGtcNyaQ+cFAZfZnYL05uj+XINQS6yQY5gQ8=";
              allowedIPs = [
                "192.168.20.0/24"
                "2600:6c4a:7880:3220::/64"
                "fd9e:1a04:f01d:20::/64"
                "fe80::10/128"
              ];
            }
          ];
        };
      };
    };

    nat.enable = false;
    firewall.enable = false;
  };
}
