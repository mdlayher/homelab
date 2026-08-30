{
  config,
  lib,
  pkgs,
  ...
}:

let
  inventory = config.homelab.inventory;
in
{
  services.corerad = {
    enable = true;

    # Enable as necessary to get development builds of CoreRAD.
    package = pkgs.unstable.corerad;

    settings = with inventory.interfaces; {
      # Base non-interface configuration.
      debug = {
        # No risk exposing these off-host because of the WAN firewall.
        address = ":9430";
        prometheus = true;
        pprof = true;
      };

      interfaces =
        # Upstream monitoring interfaces.
        [
          {
            # Spectrum, Metronet does not provide IPv6 as of September 2023.
            names = [ "wan0" ];
            monitor = true;
          }
        ]

        # Downstream advertising interfaces.
        ++ lib.forEach [ mgmt0 lan0 guest0 iot0 dev0 ] (
          ifi:
          {
            name = ifi.name;
            advertise = true;

            # Configure a higher preference for interfaces with more bandwidth.
            preference = ifi.preference;

            # Advertise all /64 prefixes on the interface.
            prefix = [
              # RFC8978: Reaction of IPv6 SLAAC to Flash-Renumbering Events
              {
                preferred_lifetime = "45m";
                valid_lifetime = "90m";
              }
            ];

            # Automatically use the appropriate interface address as a DNS server.
            rdnss = [ { } ];

            # Automatically propagate routes owned by loopback.
            route = [
              # Tuning inspired by:
              # RFC8978: Reaction of IPv6 SLAAC to Flash-Renumbering Events
              {
                lifetime = "45m";
              }
            ];
          }
          # Configure DNS search on trusted LANs, or omit otherwise.
          // lib.optionalAttrs ifi.trusted {
            dnssl = [ { domain_names = [ inventory.domain ]; } ];
          }
        );
    };
  };
}
