# Variables referenced two or more places in the configuration.
let
  server_ipv4 = "192.168.1.4";
  server_ipv6 = "2600:6c4a:7880:3200:1e1b:dff:feea:830f";

  # Configuration variables which are used to build out configs elsewhere.
in {
  inherit server_ipv4;
  inherit server_ipv6;

  domain = "lan.servnerr.com";
  hosts = {
    # Machines that are remotely accessible and run services.
    servers = [
      {
        name = "monitnerr-1";
        ipv4 = "192.168.1.11";
        ipv6 = {
          gua = "2600:6c4a:7880:3200:dea6:32ff:fe1e:6694";
          ula = "fd9e:1a04:f01d:0:dea6:32ff:fe1e:6694";
        };
        mac = "dc:a6:32:1e:66:94";
      }
      {
        name = "nerr-3";
        ipv4 = "192.168.1.9";
        ipv6 = {
          gua = "2600:6c4a:7880:3200:6d9:f5ff:fe7e:1c47";
          ula = "fd9e:1a04:f01d:0:6d9:f5ff:fe7e:1c47";
        };
        mac = "04:d9:f5:7e:1c:47";
      }
      {
        name = "servnerr-3";
        ipv4 = server_ipv4;
        ipv6 = {
          gua = server_ipv6;
          ula = "fd9e:1a04:f01d:0:1e1b:dff:feea:830f";
        };
        mac = "1c:1b:0d:ea:83:0f";
      }
    ];
    # Machines which are considered network infrastructure and not exposed
    # externally.
    infra = [
      {
        name = "switch-livingroom01";
        ipv4 = "192.168.1.2";
        ipv6.ula = "fd9e:1a04:f01d:0:f29f:c2ff:fe0b:28ca";
        mac = "f0:9f:c2:0b:28:ca";
      }
      {
        name = "switch-office01";
        ipv4 = "192.168.1.3";
        ipv6.ula = "fd9e:1a04:f01d:0:f29f:c2ff:fece:7ee1";
        mac = "f0:9f:c2:ce:7e:e1";
      }
      {
        name = "ap-livingroom02";
        ipv4 = "192.168.1.5";
        ipv6.ula = "fd9e:1a04:f01d::7683:c2ff:fe7a:c615";
        mac = "74:83:c2:7a:c6:15";
      }
    ];
  };
  interfaces = {
    wan0 = {
      name = "enp1s0";
      ipv4 = "24.176.57.23";
    };
    lan0 = {
      name = "enp2s0";
      internal_domain = true;
      ipv4 = "192.168.1.1";
      ipv6 = {
        lla = "fe80::20d:b9ff:fe53:eacd";
        ula = "fd9e:1a04:f01d::1";
      };
    };
    guest0 = {
      name = "guest0";
      internal_domain = false;
      ipv4 = "192.168.9.1";
      ipv6 = {
        lla = "fe80::20d:b9ff:fe53:eacd";
        ula = "fd9e:1a04:f01d:9::1";
      };
    };
    iot0 = {
      name = "iot0";
      internal_domain = false;
      ipv4 = "192.168.66.1";
      ipv6 = {
        lla = "fe80::20d:b9ff:fe53:eacd";
        ula = "fd9e:1a04:f01d:66::1";
      };
    };
    lab0 = {
      name = "lab0";
      internal_domain = false;
      ipv4 = "192.168.2.1";
      ipv6 = {
        lla = "fe80::20d:b9ff:fe53:eacd";
        ula = "fd9e:1a04:f01d:2::1";
      };
    };
    wg0 = {
      name = "wg0";
      ipv4 = "192.168.20.1";
      ipv6 = {
        # TODO try to get prefix delegation ordering working.
        gua = "2600:6c4a:7880:3220::1";
        lla = "fe80::";
        ula = "fd9e:1a04:f01d:20::1";
      };
    };
  };
  localhost = {
    ipv4 = "127.0.0.1";
    ipv6 = "::1";
  };
}
