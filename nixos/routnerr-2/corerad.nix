{ lib, ... }:

let vars = import ./lib/vars.nix;

in {
  services.corerad = {
    enable = true;
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
        ++ lib.forEach [ enp2s0 lab0 lan0 corp0 guest0 iot0 tengb0 ] (ifi: {
          name = ifi.name;
          advertise = true;

          # Configure a higher preference for interfaces with more bandwidth.
          # TODO: factor out this metric so we don't have to match on name.
          preference = if ifi.name == "tengb0" then "high" else "medium";

          # Advertise all /64 prefixes on the interface.
          prefix = [{ prefix = "::/64"; }];

          # Use the router's ULA address as a DNS server.
          rdnss = [{ servers = [ ifi.ipv6.ula ]; }];

          # Configure DNS search on some trusted LANs, or omit otherwise.
          dnssl = if ifi.internal_domain then [{
            domain_names = [ vars.domain ];
          }] else
            [ ];
        });
    };
  };
}
