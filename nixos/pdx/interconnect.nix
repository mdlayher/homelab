{ config, lib, ... }:

# This site's end of the circuit to azo. The module (nixos/modules/
# interconnect.nix, imported by dn42.nix) owns the shape; this file supplies
# the addresses and the identity.
let
  inventory = config.homelab.inventory;
  isis = inventory.isis;

  # The first /127 of the interconnect carrier /56. azo takes ::1, this end
  # takes ::0.
  carrier = lib.removeSuffix "00::/56" inventory.interconnectPrefix;
  link = "${carrier}00::";
in
{
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

      links.azo = {
        # azo's carrier key, which is its dn42 key reused. Written out
        # because it is a peer's: homelab.dn42.publicKey names this host's
        # own key, which on pdx is pdx's.
        publicKey = "yHaVotqyBwnDqT9mj4t28fFnpLyAGosU3gOq/ngmkHk=";
        port = 51821;

        # No endpoint: azo's WAN address is dynamic, so it initiates and
        # this end learns where it is from the handshake.
        endpoint = null;

        localAddress = "${link}/127";
        remoteAddress = "${link}1";
        localLla = "fe80::2";
        lla = "fe80::1";
      };

      isis = {
        enable = true;
        net = "${isis.area}.${isis.systemIds.pdx}.00";

        # The loopback, as at azo: this router's identity, which nothing
        # else advertises. There are no site LANs here to add.
        passiveInterfaces = [ "dn42" ];
      };
    };
  };
}
