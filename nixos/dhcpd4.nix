{ config, lib, ... }:

let
  vars = import ./vars.nix;

  guest0 = vars.interfaces.guest0;
  iot0 = vars.interfaces.iot0;
  lab0 = vars.interfaces.lab0;
  lan0 = vars.interfaces.lan0;

in {
  services.dhcpd4 = {
    interfaces =
      [ "${lan0.name}" "${guest0.name}" "${iot0.name}" "${lab0.name}" ];
    enable = true;
    machines = [
      {
        hostName = "switch-livingroom01";
        ethernetAddress = "f0:9f:c2:0b:28:ca";
        ipAddress = "192.168.1.2";
      }
      {
        hostName = "switch-office01";
        ethernetAddress = "f0:9f:c2:ce:7e:e1";
        ipAddress = "192.168.1.3";
      }
      {
        hostName = "ap-livingroom01";
        ethernetAddress = "44:d9:e7:02:2a:56";
        ipAddress = "192.168.1.5";
      }
      {
        hostName = "hdhomerun";
        ethernetAddress = "00:18:dd:32:52:c0";
        ipAddress = "192.168.1.8";
      }
    ] ++ lib.forEach vars.hosts.servers (host:
      {
        hostName = host.name;
        ethernetAddress = host.mac;
        ipAddress = host.ipv4;
      }
    );
    extraConfig = ''
      ddns-update-style none;

      default-lease-time 86400;
      max-lease-time 86400;

      ${lib.concatMapStrings (ifi:
        # Since dhcpd4 doesn't speak CIDR notation, trim off the final octet of
        # the router's address for our "/24" prefix.
        let pfx = lib.removeSuffix ".1" ifi.ipv4;
        in ''
          subnet ${pfx}.0 netmask 255.255.255.0 {
            option subnet-mask 255.255.255.0;
            option broadcast-address ${pfx}.255;
            option routers ${ifi.ipv4};
            option domain-name-servers ${ifi.ipv4};
            range ${pfx}.20 ${pfx}.240;

            ${
            # Configure DNS search for the primary internal LAN.
              if ifi.internal_domain then ''
                option domain-search "${vars.domain}";
                  option domain-name "${vars.domain}";
              '' else
                ""
            }
          }
            '') [ lan0 guest0 iot0 lab0 ]}
    '';
  };
}
