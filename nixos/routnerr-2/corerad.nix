{ lib, ... }:

let
  vars = import ./lib/vars.nix;
  unstable = import <nixos-unstable-small> { };

in {
  services.corerad = {
    enable = true;

    # Use unstable for newer CoreRAD.
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
        lib.forEach [ wan0 ] (ifi: {
          name = ifi.name;
          monitor = true;
        })

        # Downstream advertising interfaces.
        ++ lib.forEach [ enp2s0 lab0 lan0 guest0 iot0 tengb0 ] (ifi: {
          name = ifi.name;
          advertise = true;

          # Configure a higher preference for interfaces with more bandwidth.
          preference = ifi.preference;

          # Advertise all /64 prefixes on the interface.
          prefix = [{ prefix = "::/64"; }];

          # Automatically use the appropriate interface address as a DNS server.
          rdnss = [{ servers = ["::"]; }];

          # Configure DNS search on some trusted LANs, or omit otherwise.
          dnssl = [{ domain_names = [ vars.domain ]; }];
        });
    };
  };
}
