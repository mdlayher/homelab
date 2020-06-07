{ lib, pkgs, ... }:

let
  vars = import ./lib/vars.nix;
  unstable = import <unstable> { };

in {
  services.corerad = {
    enable = true;
    # Use unstable package until CoreRAD BETA lands in 20.03 stable.
    package = unstable.corerad;
    configFile = pkgs.writeText "corerad.toml" ''
      # CoreRAD BETA configuration file.

      [debug]
      address = ":9430"
      prometheus = true
      pprof = true

      ${with vars.interfaces;
      # Set up upstream monitoring interfaces.
      lib.concatMapStrings (ifi: ''
        [[interfaces]]
        name = "${ifi.name}"
        monitor = true
      '') [ wan0 ]}

      ${with vars.interfaces;
      # Set up downstream advertising interfaces, with the notable exception of
      # lab0 which runs its own build and config for CoreRAD.
      lib.concatMapStrings (ifi: ''
        [[interfaces]]
        name = "${ifi.name}"
        advertise = true
        other_config = true

        ${
        # Special configuration for the 10GbE LAN.
        if ifi.name == tengb0.name then ''
          preference = "high"
          mtu = 9000
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
              '') [ enp2s0 lan0 guest0 iot0 tengb0 ]}
          '';
  };
}
