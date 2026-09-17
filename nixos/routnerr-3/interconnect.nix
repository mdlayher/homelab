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
in
{
  imports = [ ../modules/interconnect.nix ];

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
