{
  config,
  lib,
  ...
}:

# This machine's attachment to the IGP. It terminates no circuit to another
# site; it runs the protocol so the resolver it holds an anycast address for
# can be found, and withdrawn, the same way every other node's is.

let
  inventory = config.homelab.inventory;

  # This site's link between its own routers, from the inventory: each end
  # reads its own addresses and the far end's out of the one registry.
  siteLink = inventory.siteLinks.${config.homelab.site};
  ours = siteLink.${config.networking.hostName};
  far = lib.head (lib.attrValues (lib.filterAttrs (n: _: n != config.networking.hostName) siteLink));
in
{
  imports = [ ../modules/interconnect.nix ];

  config = {
    homelab.interconnect = {
      # The link to this site's router, matching the far end's declaration
      # (nixos/routnerr-3/interconnect.nix). A link of its own rather than
      # the management LAN: a circuit advertises the prefixes on its
      # interface, and a LAN's are a secret subnet and a delegated GUA that
      # renumbers.
      links.router0 = {
        site = config.homelab.site;
        carrier = null;
        interface = ours.interface;
        localAddress = "${ours.carrier}/127";
        remoteAddress = far.carrier;
        localCircuitAddress = "${ours.circuit}/127";
        localLla = ours.lla;
        lla = far.lla;
        # The segment's 1500 less the GRETAP's 66. The module's default is
        # sized for a WireGuard carrier, which this link has none of.
        mtu = 1434;
      };

      isis = {
        enable = true;

        # No aggregate: the site's prefix is originated by the router, and a
        # second copy of it here would be a second door into the same
        # prefix. What this machine puts into the IGP is the anycast address
        # it answers at, which nixos/modules/anycast.nix advertises for as
        # long as the service behind it runs.
      };
    };
  };
}
