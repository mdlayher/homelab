{ config, lib, pkgs, ... }:

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

      [debug]
      address = ":9430"
      prometheus = true
      pprof = true

      ${lib.concatMapStrings (ifi: ''
        [[interfaces]]
        name = "${ifi.name}"
        send_advertisements = true
        other_config = true

          [[interfaces.prefix]]
          prefix = "::/64"

          [[interfaces.rdnss]]
          servers = ["${ifi.ipv6.ula}"]

              ${
              # Configure DNS search for the primary internal LAN.
                if ifi.internal_domain then ''
                  [[interfaces.dnssl]]
                  domain_names = ["${vars.domain}"]
                '' else
                  ""
              }
              '') [ lan0 guest0 iot0 lab0 ]}
          '';
  };
}
