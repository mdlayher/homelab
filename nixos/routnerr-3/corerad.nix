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

            # Route information, tuned per RFC 8978 (Reaction of IPv6 SLAAC
            # to Flash-Renumbering Events). Trusted LANs get every prefix
            # the router owns, the routes on loopback: the site ULA and
            # delegated GUA aggregates. Restricted LANs get the site ULA
            # alone, and explicitly: the loopback routes also include
            # bird's unreachable dn42 aggregate, and a dev0 host on the
            # internal dn42 VLAN would then reach our own dn42 space
            # through dev0 instead of that VLAN. The site ULA it still
            # needs, since the dn42 VLAN's fd00::/8 route would otherwise
            # capture the site's ULA traffic too.
            route = [
              (
                {
                  lifetime = "45m";
                }
                // lib.optionalAttrs (!ifi.trusted) { prefix = inventory.ulaPrefix; }
              )
            ];
          }
          # Configure DNS search on trusted LANs, or omit otherwise.
          // lib.optionalAttrs ifi.trusted {
            dnssl = [ { domain_names = [ inventory.domain ]; } ];
          }
        )

        # The internal dn42 VLAN (see dn42.nix): SLAAC for its /64, and
        # dn42 reached through the router by route information rather than
        # a default route. A zero router lifetime keeps the router out of
        # hosts' default router lists: the container on the far end already
        # defaults out dev0, and the dn42 side forwards nowhere but dn42.
        # The route covers all of dn42's IPv6 space, the fd00::/8 that the
        # import filter accepts; a host's site ULA and tailnet prefixes are
        # more specific and stay on their own interfaces. No RDNSS until
        # the router serves DNS on the internal side (see nftables.nix).
        ++ lib.optional config.homelab.dn42.dev0.enable {
          name = "dn42i-dev0";
          advertise = true;
          default_lifetime = "0s";
          prefix = [
            {
              preferred_lifetime = "45m";
              valid_lifetime = "90m";
            }
          ];
          route = [
            {
              prefix = "fd00::/8";
              lifetime = "45m";
            }
          ];
        };
    };
  };
}
