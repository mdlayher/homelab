locals {
  # Bootstrap access only: the NixOS AMI takes its root key from instance
  # metadata, and the first nixos/deploy replaces it with the real user from
  # nixos/modules/common.nix. Keep this equal to the key there.
  ssh_public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIN5i5d0mRKAf02m+ju+I1KrAYw3Ny2IHXy88mgyragBN Matt Layher (mdlayher@gmail.com)"
}
