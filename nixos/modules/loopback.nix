# This router's loopback: one address on no segment, carried by the IGP.
#
# A machine at a site with no LAN has nowhere else to be named or reached,
# and a machine at a site with one still wants an address that outlives any
# single interface. The registry is nixos/inventory/default.nix, keyed by
# machine name, and it is plain data rather than a sops placeholder: a
# loopback is read across sites, by the resolver answering for a site it is
# not at and by the server naming a scrape target elsewhere, and a
# placeholder only means anything on the machine which declared the secret.
#
# Names the address to the IGP as well as creating it, which is why
# modules/interconnect.nix imports it rather than each machine doing so. A
# loopback nothing advertises would be an address only its own host could
# reach.
{
  config,
  lib,
  ...
}:

let
  loopback = config.homelab.inventory.loopbacks.${config.networking.hostName} or null;
in
lib.mkIf (loopback != null) {
  systemd.network = {
    netdevs."50-site" = {
      netdevConfig = {
        Name = "site";
        Kind = "dummy";
      };
    };

    networks."50-site" = {
      matchConfig.Name = "site";
      address = [
        "${loopback.addr6}/128"
      ]
      ++ lib.optional (loopback.addr4 != null) "${loopback.addr4}/32";
    };
  };

  # Advertised or invisible: there is no third state, so the module which
  # creates the address is the one which names it to the IGP. A separate
  # interface from the dn42 dummy because a dn42 interface may never carry
  # the ULA; see modules/interconnect.nix.
  homelab.interconnect.isis.passiveInterfaces = [ "site" ];
}
