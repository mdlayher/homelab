{ config, lib, ... }:

let
  vars = import ./vars.nix;

  guest0 = vars.interfaces.guest0;
  iot0 = vars.interfaces.iot0;
  lab0 = vars.interfaces.lab0;
  lan0 = vars.interfaces.lan0;

  # Produces a compatible object for the dhcpd4 machines array.
  mkHost = (host: {
    hostName = host.name;
    ethernetAddress = host.mac;
    ipAddress = host.ipv4;
  });

in {
  services.dhcpd4 = {
    interfaces =
      [ "${lan0.name}" "${guest0.name}" "${iot0.name}" "${lab0.name}" ];
    enable = true;
    machines = lib.forEach (vars.hosts.infra ++ vars.hosts.servers) mkHost;
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

            allow booting;
            next-server ${ifi.ipv4};
            option bootfile-name "netboot.xyz.kpxe";

            ${
            # Configure additional options for the primary internal LAN.
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
