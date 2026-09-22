{ ... }:

# The edge at the iad site, in us-east-1. What is true of every edge is in
# modules/aws-edge.nix; this file names the site, and interconnect.nix the
# circuits that end here.
{
  imports = [
    ../modules/aws-edge.nix
    ./interconnect.nix
    ./dn42.nix
  ];

  # Its own site, with no subnets: nothing here is named in internal DNS and
  # no inventory secret is decrypted. See nixos/inventory/.
  homelab.site = "iad";

  system.stateVersion = "26.05";
}
