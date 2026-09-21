# The WireGuard exporter, on every machine running a tunnel: handshake age
# and byte counters per peer, beneath whatever rides the tunnel. Imported
# by the modules which create tunnels, dn42 for its peers and interconnect
# for its carriers, and inert on a machine with neither.
#
# This is MindFlavor's exporter from nixpkgs, which shells out to `wg show
# all dump` under CAP_NET_ADMIN. Its metrics carry an interface label, so
# dn42e-<peer> and iclw-<site><plane> already name the far end; the
# exporter's friendly name mapping reads a wg-quick configuration file,
# which these networkd-managed tunnels do not have, and would only repeat
# what the interface name says. Scraped by the server's exporter discovery.
{ config, lib, ... }:

let
  carriers = lib.any (link: link.carrier != null) (
    lib.attrValues (config.homelab.interconnect.links or { })
  );
  peers = (config.homelab.dn42.peers or { }) != { };
in
{
  config = lib.mkIf (carriers || peers) {
    services.prometheus.exporters.wireguard = {
      enable = true;
      # Both families. The default is 0.0.0.0, and this exporter takes that
      # literally where the others end up dual-stack from the same string,
      # so at a site whose only name is an AAAA it is the one target that
      # cannot be scraped.
      listenAddress = "::";
      # Export the age of each peer's last handshake alongside its UNIX
      # timestamp, so the alert compares one number to a threshold rather
      # than subtracting this machine's clock from the server's.
      latestHandshakeDelay = true;
    };
  };
}
