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

            # The anycast address alone (see modules/anycast.nix), not this
            # interface's own. Both are answered by the same process here,
            # so advertising the interface address as well offers no second
            # chance: it fails at the same moment and, unlike the anycast
            # address, the IGP cannot move it to a node which is still
            # serving. A client which happened to try it first would wait
            # out a timeout before reaching one that answers.
            rdnss = [ { servers = [ inventory.anycast6.dns ]; } ];

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
          # DNS search: this segment's own namespace, and on a trusted LAN
          # the other trusted namespaces and the site domain after it, so a
          # bare name resolves across the LANs a host may actually reach. A
          # restricted LAN gets its own alone, since it cannot reach the
          # others. A segment the inventory names no host on has nothing to
          # search for and is told nothing.
          // lib.optionalAttrs (ifi.hosts != [ ]) {
            dnssl = [
              {
                domain_names = [
                  ifi.searchDomain
                ]
                ++ lib.optionals ifi.trusted (
                  (map (i: i.searchDomain) (
                    lib.filter (i: i.trusted && i.name != ifi.name) (lib.attrValues inventory.interfaces)
                  ))
                  ++ [ inventory.domain ]
                );
              }
            ];
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
        ++ map (vlan: {
          name = vlan.interface;
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
        }) (lib.attrValues config.homelab.dn42.vlans);
    };
  };
}
