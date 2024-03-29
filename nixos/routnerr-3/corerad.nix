{ lib, ... }:

let
  unstable = import <nixos-unstable-small> { };
  vars = import ./lib/vars.nix;

in {
  services.corerad = {
    enable = true;

    # Enable as necessary to get development builds of CoreRAD.
    package = unstable.corerad;

    settings = with vars.interfaces; {
      # Base non-interface configuration.
      debug = {
        # No risk exposing these off-host because of the WAN firewall.
        address = ":9430";
        prometheus = true;
        pprof = true;
      };

      interfaces =
        # Upstream monitoring interfaces.
        [{
          # Spectrum, Metronet does not provide IPv6 as of September 2023.
          names = [ "wan0" ];
          monitor = true;
        }]

        # Downstream advertising interfaces.
        ++ lib.forEach [ mgmt0 lab0 lan0 guest0 iot0 ] (ifi:
          {
            name = ifi.name;
            advertise = true;

            # Configure a higher preference for interfaces with more bandwidth.
            preference = ifi.preference;

            # Advertise all /64 prefixes on the interface.
            prefix = [ { } ];

            # Automatically use the appropriate interface address as a DNS server.
            rdnss = [ { } ];

            # Automatically propagate routes owned by loopback.
            route = [ { } ];
          } // (
            # Configure DNS search on some trusted LANs, or omit otherwise.
            #
            # TODO(mdlayher): probably rename to ifi.trusted.
            if ifi.internal_dns then {
              dnssl = [{ domain_names = [ vars.domain ]; }];
            } else
              { }));
    };
  };
}
