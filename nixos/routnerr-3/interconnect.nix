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
  isis = inventory.isis;

  # The first /127 of the interconnect carrier /56; pdx takes ::0.
  carrier = lib.removeSuffix "00::/56" inventory.interconnectPrefix;
  pdxLink = "${carrier}00::";
in
{
  config = {
    homelab.interconnect = {
      # One key for the dn42 tunnels and the carrier both. A separate one
      # keeps the two blast radii apart; this reuses it because the public
      # half is already published and pdx can name it rather than repeat it.
      privateKeyFile = config.sops.secrets."dn42/wireguard_key".path;

      links.pdx = {
        publicKey = "7gO2i3ZxZFosAOuRZgC5yFIM/8fBX+KqVEo/HoWajD8=";
        port = 51821;

        # We initiate, because this WAN address is dynamic and pdx's is not.
        # The name is where pdx's addresses are written down, in
        # terraform/cloudflare; networkd resolves it.
        endpoint = "pdx.dn42.mdlayher.net:51821";

        localAddress = "${pdxLink}1/127";
        remoteAddress = "${pdxLink}";
        localLla = "fe80::1";
        lla = "fe80::2";
      };

      isis = {
        enable = true;
        # Area and system ID come from the inventory, which explains the
        # scheme and is the registry for both; the NSAP selector is always
        # 00 for a router's own NET.
        net = "${isis.area}.${isis.systemIds.routnerr-3}.00";

        # The whole site in one prefix, so the far end has a route home
        # without this router advertising a LAN. The unreachable aggregate
        # on loopback is the route it matches (see networking.nix); the
        # more specific LANs sort traffic out once it arrives, and anything
        # nobody holds meets the aggregate and is rejected here.
        aggregate = inventory.ulaPrefix;

        # What this router puts into the IGP beyond the circuit itself.
        #
        # "dn42" is the dummy holding this router's loopback addresses, not
        # a dn42 VLAN -- that is dn42i-dev0. The loopback is the router's
        # identity and nothing else would advertise it. "site" is the same
        # in our own space, and modules/loopback.nix adds it here.
        #
        # The site LANs are not named, and will not be: the aggregate above
        # says what they would, without also handing the far site a GUA
        # this router does not control. dn42's ibgpInternal is a separate
        # question from this one -- bird rejects the site ULA in every
        # filter it has, so the LANs have never travelled that way and the
        # prefixes that switch still carries are dn42's own.
        passiveInterfaces = [ "dn42" ];
      };
    };
  };
}
