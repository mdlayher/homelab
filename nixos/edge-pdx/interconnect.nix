{ config, ... }:

# This site's end of the circuits to azo. The module owns the shape; this
# file supplies the addresses and the identity.

let
  # azo's carrier key, which is its dn42 key reused, and the same for both
  # carriers: one key identifies that router. Written out because it is a
  # peer's -- homelab.dn42.publicKey names this host's own key, which here
  # is pdx's.
  azoPublicKey = "yHaVotqyBwnDqT9mj4t28fFnpLyAGosU3gOq/ngmkHk=";
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
      # No endpoint on either: azo's WAN addresses are dynamic, so it
      # initiates and this end learns where it is from the handshake. The
      # ports are the module's, derived from the two sites' indices and the
      # plane, so they match what azo dials without being repeated here.
      links.azo0 = {
        site = "azo";
        publicKey = azoPublicKey;
        endpoint = null;
      };

      links.azo1 = {
        site = "azo";
        plane = 1;
        publicKey = azoPublicKey;
        endpoint = null;
      };

      isis.enable = true;
    };
  };
}
