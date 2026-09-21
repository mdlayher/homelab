{ config, ... }:

# Tailscale at an edge site. tailscaled keeps these in its own state, so a
# node reauthenticated by hand comes back with whatever flags were typed
# that day; declaring them means an activation puts them back.
# --accept-dns=false is set for every machine in modules/tailscale.nix and
# merges with these.
#
# The tag is not here and cannot be: `tailscale set` has no
# --advertise-tags, so a tag belongs to the login rather than to the
# configuration. An edge is tagged at `tailscale up --advertise-tags=tag:edge`
# when it first joins, and that tag is what the policy grants on -- personal
# devices reach an edge, and the development container reaches port 22 to
# deploy to it. Untagged, no rule matches and the machine is unreachable
# over the tailnet.
{
  services.tailscale.extraSetFlags = [
    # This machine's own name, not the one DHCP hands it. EC2's transient
    # hostname would otherwise name the node in the tailnet, as it would
    # have named it to IS-IS and to Loki.
    "--hostname=${config.networking.hostName}"

    # Not Tailscale SSH. Turning it on makes tailscaled answer port 22 for
    # every tailnet connection, which takes the port away from sshd: the
    # deploys that ride tag:dev reach tailscaled instead and are refused,
    # because the ssh policy grants only autogroup:member. Widening that to
    # tag:dev would be worse than the problem -- it would let the
    # development container in without the admin's key, and agents run there.
    #
    # The admin console's SSH Console is worth having on a machine with no
    # LAN, but it needs sshd on a second port to coexist with key-based
    # deploys. That is a decision to take before the public port closes, not
    # a flag.
    "--ssh=false"
  ];
}
