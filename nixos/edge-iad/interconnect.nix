{ config, ... }:

# This site's end of the circuits it terminates. The module owns the shape;
# this file supplies the addresses and the identity.

let
  # The far ends' carrier keys, each written out because it belongs to that
  # router rather than to this one. azo reuses its dn42 key for the carrier;
  # pdx has one of its own.
  azoPublicKey = "yHaVotqyBwnDqT9mj4t28fFnpLyAGosU3gOq/ngmkHk=";
  pdxPublicKey = "7gO2i3ZxZFosAOuRZgC5yFIM/8fBX+KqVEo/HoWajD8=";
in
{
  imports = [ ../modules/interconnect.nix ];

  config = {
    # This site's own WireGuard key, generated into the secrets file by
    # `sops-gate keygen-wg` and never read outside the gate. Separate from
    # every other site's, so no site's compromise is another's.
    sops.secrets."interconnect/wireguard_key" = {
      sopsFile = ./secrets.yaml;
      owner = "systemd-network";
      restartUnits = [ "systemd-networkd.service" ];
    };

    homelab.interconnect = {
      privateKeyFile = config.sops.secrets."interconnect/wireguard_key".path;

      # This site dials nothing: it has the highest index, so under the
      # module's rule every far end dials it and this end learns where each
      # is from the handshake. The ports are derived at both ends alike.
      #
      # One carrier per WAN toward azo, so an outage of either ISP there
      # costs one circuit rather than this site's path home.
      links.azo0 = {
        site = "azo";
        publicKey = azoPublicKey;
      };

      links.azo1 = {
        site = "azo";
        plane = 1;
        publicKey = azoPublicKey;
      };

      # One carrier toward pdx, not two: both ends have a single uplink, so
      # a second would be two carriers over one path -- redundancy that
      # reports healthy and protects nothing. It closes the ring, which is
      # what gives this site a route home when both of azo's WANs are
      # unreachable from here.
      links.pdx0 = {
        site = "pdx";
        publicKey = pdxPublicKey;
      };

      # The landing page at this site's icl names. One uplink here, so
      # HTTP-01 validates over the names themselves and no DNS credential
      # is needed on a machine reachable from the internet. The security
      # group in terraform/aws opens the ports it needs.
      page.enable = true;

      isis = {
        enable = true;

        # This site's own /56, so the others route it here rather than
        # meeting it on the /48 azo originates and rejecting it there. The
        # route this matches is the unreachable aggregate in
        # configuration.nix, which is also what answers for an address
        # inside it that nothing holds.
        aggregate6 = config.homelab.inventory.sites.${config.homelab.site}.prefix6;
        aggregate4 = [ config.homelab.inventory.sites.${config.homelab.site}.prefix4 ];
      };
    };
  };
}
