{ config, pkgs, ... }:

let
  vars = import ./vars.nix;

  guest0 = vars.interfaces.guest0;
  iot0 = vars.interfaces.iot0;
  lab0 = vars.interfaces.lab0;
  lan0 = vars.interfaces.lan0;

in {
  services.corerad = {
    enable = true;
    configFile = pkgs.writeText "corerad.toml" ''
      # CoreRAD vALPHA configuration file.

      # Primary LAN.
      [[interfaces]]
      name = "${lan0.name}"
      send_advertisements = true

        [[interfaces.plugins]]
        name = "prefix"
        prefix = "::/64"

        [[interfaces.plugins]]
        name = "rdnss"
        servers = ["${lan0.ipv6.ula}"]

        [[interfaces.plugins]]
        name = "dnssl"
        domain_names = ["${vars.domain}"]

      # Lab LAN.
      [[interfaces]]
      name = "${lab0.name}"
      send_advertisements = true
      default_lifetime = "0s"
      unicast_only = true

        [[interfaces.plugins]]
        name = "prefix"
        prefix = "::/64"

      # Secondary LANs.
      [[interfaces]]
      name = "${guest0.name}"
      send_advertisements = true

        [[interfaces.plugins]]
        name = "prefix"
        prefix = "::/64"

      [[interfaces]]
      name = "${iot0.name}"
      send_advertisements = true

        [[interfaces.plugins]]
        name = "prefix"
        prefix = "::/64"

      [debug]
      address = "[${lan0.ipv6.ula}]:9430"
      prometheus = true
      pprof = true
          '';
  };
}
