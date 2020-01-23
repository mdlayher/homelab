{ config, pkgs, ... }:

let
  vars = import ./vars.nix;
  unstable = import <unstable> { };

  guest0 = vars.interfaces.guest0;
  iot0 = vars.interfaces.iot0;
  lab0 = vars.interfaces.lab0;
  lan0 = vars.interfaces.lan0;

in {
  services.corerad = {
    enable = true;
    # Use unstable package until CoreRAD reaches stable.
    package = unstable.corerad;
    configFile = pkgs.writeText "corerad.toml" ''
      # CoreRAD vALPHA configuration file.

      # Primary LAN.
      [[interfaces]]
      name = "${lan0.name}"
      send_advertisements = true

        [[interfaces.prefix]]
        prefix = "::/64"

        [[interfaces.rdnss]]
        servers = ["${lan0.ipv6.ula}"]

        [[interfaces.dnssl]]
        domain_names = ["${vars.domain}"]

      # Lab LAN.
      [[interfaces]]
      name = "${lab0.name}"
      send_advertisements = true
      default_lifetime = "0s"
      unicast_only = true

        [[interfaces.prefix]]
        prefix = "::/64"

      # Secondary LANs.
      [[interfaces]]
      name = "${guest0.name}"
      send_advertisements = true

        [[interfaces.prefix]]
        prefix = "::/64"

      [[interfaces]]
      name = "${iot0.name}"
      send_advertisements = true

        [[interfaces.prefix]]
        prefix = "::/64"

      [debug]
      address = ":9430"
      prometheus = true
      pprof = true
          '';
  };
}
