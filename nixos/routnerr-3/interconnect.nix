{
  config,
  lib,
  ...
}:

# This site's end of the circuit to pdx. The module (nixos/modules/
# interconnect.nix) owns the shape; this file supplies the addresses, the
# identity, and what this router puts into the IGP.

let
  inventory = config.homelab.inventory;

  # pdx's carrier key, shared by both links to it: one key identifies that
  # router, and the two carriers differ by port rather than by identity.
  pdxPublicKey = "7gO2i3ZxZFosAOuRZgC5yFIM/8fBX+KqVEo/HoWajD8=";
in
{
  imports = [ ../modules/interconnect.nix ];

  config = {
    homelab.interconnect = {
      # One key for the dn42 tunnels and the carrier both. A separate one
      # keeps the two blast radii apart; this reuses it because the public
      # half is already published and pdx can name it rather than repeat it.
      privateKeyFile = config.sops.secrets."dn42/wireguard_key".path;

      # One carrier per WAN, so a single ISP outage costs one circuit rather
      # than the site. The IGP treats them as any other pair of links and,
      # at equal metrics, uses both.
      #
      # The mark is what makes them independent: without it both carriers
      # follow the main table out whichever WAN it prefers, and the two
      # adjacencies report a redundancy that does not exist. The rules and
      # the per-WAN tables the marks select are in networking.nix, which is
      # where this site's WANs are described.
      #
      # The endpoint names pin the address family, which the mark cannot and
      # which is not cosmetic here: Metronet carries no IPv6, so a carrier
      # marked for it with an IPv6 endpoint would be steered correctly and
      # then find no route in that table.
      #
      # The ports are the module's, derived from the two sites' indices and
      # the plane; the endpoints name the same numbers because both ends of
      # a link derive one value.
      #
      # We initiate on both, because this site's WAN addresses are dynamic
      # and pdx's are not. The names are pdx's interconnect endpoints in
      # terraform/cloudflare, under their own label rather than dn42's:
      # they identify the medium a circuit is built on, which will carry
      # dn42's iBGP as well as the IGP. They sit outside pdx.mdlayher.net
      # because this router answers for that zone itself.
      links.pdx0 = {
        site = "pdx";
        publicKey = pdxPublicKey;
        endpoint = "ipv6.pdx.icl.mdlayher.net:51120";
        firewallMark = 1;
      };

      links.pdx1 = {
        site = "pdx";
        plane = 1;
        publicKey = pdxPublicKey;
        endpoint = "ipv4.pdx.icl.mdlayher.net:51121";
        firewallMark = 2;
      };

      isis = {
        enable = true;

        # The whole site in one prefix, so the far end has a route home
        # without this router advertising a LAN. The unreachable aggregate
        # on loopback is the route it matches (see networking.nix); the
        # more specific LANs sort traffic out once it arrives, and anything
        # nobody holds meets the aggregate and is rejected here.
        aggregate = inventory.ulaPrefix;
      };
    };
  };
}
