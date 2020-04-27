{ lib, pkgs, ... }:

let
  vars = import ./vars.nix;
  unstable = import <unstable> { };

in {
  services.corerad = {
    enable = true;
    # Use unstable package until CoreRAD v0.2.4 lands in 20.03 stable.
    package = unstable.corerad;
    configFile = pkgs.writeText "corerad.toml" ''
      # CoreRAD v0.2.4 (BETA) configuration file.

      [debug]
      address = ":9430"
      prometheus = true
      pprof = true

      ${with vars.interfaces;
      lib.concatMapStrings (ifi: ''
        [[interfaces]]
        name = "${ifi.name}"
        advertise = true
        other_config = true

        ${
        # Treat the primary LAN as higher priority for machines on multiple LANs.
        if ifi.name == lan0.name then ''
          preference = "high"
        '' else
          ""}

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
