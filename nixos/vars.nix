{
  cfg = "/home/matt/cfg";
  domain = "lan.servnerr.com";
  hosts = {
    monitnerr-1 = {
      ipv4 = "192.168.1.11";
      ipv6 = {
        gua = "2600:6c4a:787f:d100:dea6:32ff:fe1e:6694";
        ula = "fd9e:1a04:f01d:0:dea6:32ff:fe1e:6694";
      };
    };
    nerr-3 = {
      ipv4 = "192.168.1.9";
      ipv6 = {
        gua = "2600:6c4a:787f:d100:6d9:f5ff:fe7e:1c47";
        ula = "fd9e:1a04:f01d:0:6d9:f5ff:fe7e:1c47";
      };
    };
    servnerr-3 = {
      ipv4 = "192.168.1.4";
      ipv6 = {
        gua = "2600:6c4a:787f:d100:4cb:90ff:fe4d:a259";
        ula = "fd9e:1a04:f01d:0:4cb:90ff:fe4d:a259";
      };
    };
  };
  interfaces = {
    wan0 = {
      name = "enp1s0";
      ipv4 = "24.176.57.23";
    };
    lan0 = {
      name = "enp2s0";
      dhcp_24 = "192.168.1";
      ipv4 = "192.168.1.1";
      ipv6 = {
        lla = "fe80::20d:b9ff:fe53:eacd";
        ula = "fd9e:1a04:f01d::1";
      };
    };
    guest0 = {
      name = "guest0";
      dhcp_24 = "192.168.9";
      ipv4 = "192.168.9.1";
      ipv6 = {
        lla = "fe80::20d:b9ff:fe53:eacd";
        ula = "fd9e:1a04:f01d:9::1";
      };
    };
    iot0 = {
      name = "iot0";
      dhcp_24 = "192.168.66";
      ipv4 = "192.168.66.1";
      ipv6 = {
        lla = "fe80::20d:b9ff:fe53:eacd";
        ula = "fd9e:1a04:f01d:66::1";
      };
    };
    lab0 = {
      name = "lab0";
      dhcp_24 = "192.168.2";
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
        gua = "2600:6c4a:787f:d120::1";
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
