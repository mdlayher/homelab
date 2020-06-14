{ lib, ... }:

let
  vars = import ./lib/vars.nix;

  # Produces a compatible object for the dhcpd4 machines array.
  mkHost = (host: {
    hostName = host.name;
    ethernetAddress = host.mac;
    ipAddress = host.ipv4;
  });

in {
  services.dhcpd4 = {
    interfaces = with vars.interfaces; [
      "${enp2s0.name}"
      "${lan0.name}"
      "${corp0.name}"
      "${guest0.name}"
      "${iot0.name}"
      "${lab0.name}"
      "${tengb0.name}"
    ];
    enable = true;
    machines = with vars.hosts; lib.forEach (infra ++ servers) mkHost;
    extraConfig = ''
      ddns-update-style none;

      default-lease-time 86400;
      max-lease-time 86400;

      ${with vars.interfaces;
      lib.concatMapStrings (ifi:
        # Since dhcpd4 doesn't speak CIDR notation, trim off the final octet of
        # the router's address for our "/24" prefix.
        let
          pfx = lib.removeSuffix ".1" ipv4;
          ipv4 = ifi.ipv4;

        in ''
          subnet ${pfx}.0 netmask 255.255.255.0 {
            option subnet-mask 255.255.255.0;
            option broadcast-address ${pfx}.255;
            option routers ${ipv4};
            option domain-name-servers ${ipv4};
            range ${pfx}.20 ${pfx}.240;

            allow booting;
            next-server ${ipv4};
            option bootfile-name "netboot.xyz.kpxe";

            ${
              let
                domain = vars.domain;
                # Configure additional options for the primary internal LAN.
              in if ifi.internal_domain then ''
                option domain-search "${domain}";
                  option domain-name "${domain}";
              '' else
                ""
            }
          }
            '') [ enp2s0 lan0 corp0 guest0 iot0 lab0 tengb0 ]}
    '';
  };
}
