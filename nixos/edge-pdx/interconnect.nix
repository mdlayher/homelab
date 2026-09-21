{ config, ... }:

# This site's end of the circuits to azo. The module owns the shape; this
# file supplies the addresses and the identity.

let
  # azo's carrier key, which is its dn42 key reused, and the same for both
  # carriers: one key identifies that router. Written out because it is a
  # peer's -- homelab.dn42.publicKey names this host's own key, which here
  # is pdx's.
  azoPublicKey = "yHaVotqyBwnDqT9mj4t28fFnpLyAGosU3gOq/ngmkHk=";
  iadPublicKey = "l//gZ3Af+Cr9QXNFjNdOy4Tl5K5Rl3X9QEnXhxMVf3U=";
in
{
  imports = [ ../modules/interconnect.nix ];

  config = {
    # This site's own WireGuard key. Separate from azo's, so neither site's
    # compromise is the other's.
    sops.secrets."interconnect/wireguard_key" = {
      sopsFile = ./secrets.yaml;
      owner = "systemd-network";
      restartUnits = [ "systemd-networkd.service" ];
    };

    homelab.interconnect = {
      privateKeyFile = config.sops.secrets."interconnect/wireguard_key".path;

      # One carrier per WAN at azo, so an outage of either ISP there costs
      # one circuit rather than this site's only path home. Nothing needs
      # pinning at this end: there is one interface, and azo's marks decide
      # which of its WANs each carrier leaves by.
      #
      # azo dials these, as the lower index does under the module's rule,
      # and this end learns where it is from the handshake; the ports are
      # derived at both ends alike.
      links.azo0 = {
        site = "azo";
        publicKey = azoPublicKey;
      };

      links.azo1 = {
        site = "azo";
        plane = 1;
        publicKey = azoPublicKey;
      };

      # One carrier toward iad, not two: both ends have a single uplink, so
      # a second would be two carriers over one path. This end dials, as the
      # lower index does, at the endpoint the module derives.
      links.iad0 = {
        site = "iad";
        publicKey = iadPublicKey;
      };

      # The landing page at this site's icl names. One uplink here, so
      # HTTP-01 validates over the names themselves and no DNS credential
      # is needed on a machine reachable from the internet. The security
      # group in terraform/aws opens the ports it needs.
      page.enable = true;

      isis = {
        enable = true;

        # This site's own /56, so azo routes it here rather than meeting it
        # on the /48 it originates and rejecting it there. The route this
        # matches is the unreachable aggregate in configuration.nix, which
        # is also what answers for an address inside it that nothing holds.
        aggregate6 = config.homelab.inventory.sites.${config.homelab.site}.prefix6;
        aggregate4 = [ config.homelab.inventory.sites.${config.homelab.site}.prefix4 ];
      };
    };
  };
}
