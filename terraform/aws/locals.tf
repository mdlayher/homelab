locals {
  # "pdx" is the site, not the machine. Everything here is the site: the VPC
  # and its tags, the security group's name, and
  # homelab.interconnect.links.pdx, which derives the circuit's interface
  # names from it (icl-pdx, iclw-pdx). The machine at it is edge-pdx, whose
  # NixOS configuration is nixos/edge-pdx; nothing in this module names it,
  # which is why a machine rename costs no terraform state.
  region = "us-west-2"
  site   = "pdx"

  # The VPC exists to hold one host, and none of it is reachable from the
  # other site: the interconnect carries our own addressing on top. Chosen
  # not to overlap homelab.inventory.privatePrefix (192.168.0.0/16).
  vpc_cidr    = "10.80.0.0/16"
  subnet_cidr = "10.80.0.0/24"

  # The WireGuard carrier's listen port here, matched by
  # homelab.interconnect.links.pdx.port at azo. Not a secret: it is in the
  # NixOS configuration, which is public.
  wireguard_port = 51821

  # Bootstrap access only: the NixOS AMI takes its root key from instance
  # metadata, and the first nixos/deploy replaces it with the real user from
  # nixos/modules/common.nix. Keep this equal to the key there.
  ssh_public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIN5i5d0mRKAf02m+ju+I1KrAYw3Ny2IHXy88mgyragBN Matt Layher (mdlayher@gmail.com)"
}
