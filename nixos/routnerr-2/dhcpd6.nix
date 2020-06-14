{ lib, ... }:

let
  vars = import ./lib/vars.nix;
  lans = with vars.interfaces; [ enp2s0 lan0 corp0 guest0 iot0 lab0 tengb0 ];

in {
  services.dhcpd6 = {
    interfaces = lib.forEach lans (lan: toString lan.name);
    enable = true;
    extraConfig = ''
      ddns-update-style none;

      default-lease-time 600;
      max-lease-time 600;

      option dhcp6.bootfile-url code 59 = string;

      option dhcp6.rapid-commit;

      ${with vars.interfaces;
      lib.concatMapStrings (ifi:
        # Router ULA addresses have a ::1 suffix, so trim the 1 from the
        # router's address for our /64 prefix.
        let
          pfx = lib.removeSuffix "1" ifi.ipv6.ula;
          ipv6 = ifi.ipv6.ula;
        in ''
          subnet6 ${pfx}/64 {
            range6 ${pfx}ffff:1000 ${pfx}ffff:ffff;
            range6 ${pfx} temporary;

            option dhcp6.name-servers ${ipv6};

            # TODO: find a working IPv6 TFTP implementation and enable.
            # option dhcp6.bootfile-url "tftp://[${ipv6}]/netboot.xyz.kpxe";

            ${
            # Configure additional options for the primary internal LAN.
              if ifi.internal_domain then ''
                option dhcp6.domain-search "${vars.domain}";
              '' else
                ""
            }
          }
            '') lans}
    '';
  };
}
