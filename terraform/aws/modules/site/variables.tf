variable "site" {
  type        = string
  description = <<-EOT
    The site, not the machine: it names the VPC and its tags, the security
    group, and homelab.interconnect.links.<site> at the far end, which
    derives the circuit's interface names from it (icl-<site>, iclw-<site>).
  EOT
}

variable "vpc_cidr" {
  type        = string
  description = <<-EOT
    The VPC exists to hold one host, and none of it is reachable from
    another site: the interconnect carries our own addressing on top. Drawn
    from homelab.inventory.cloudPrefix4 (10.64.0.0/10), the block the
    addressing scheme reserves for exactly this, and disjoint from every
    other site's.
  EOT
}

variable "subnet_cidr" {
  type        = string
  description = "The one subnet in vpc_cidr the host sits on."
}

variable "availability_zone" {
  type        = string
  default     = null
  description = <<-EOT
    The zone the subnet is in. Named before the first apply, because not
    every zone offers every instance type: us-east-1e has no t3, and a
    subnet placed there takes the instance down with it at launch. After
    that it is a record of where the site landed: the subnet ignores a
    changed value, since a subnet cannot move, and a pin that disagrees
    with it fails the plan naming the real zone. Null leaves the choice to
    AWS and records nothing.
  EOT
}

variable "carrier_ports" {
  type        = set(string)
  description = <<-EOT
    The WireGuard carriers' listen ports at this site, one per circuit end.

    nixos/modules/interconnect.nix derives these as 51<a><b><plane> from the
    two sites' indices and the plane, so both ends reach the same number
    without either being told. Not secrets: they are in the NixOS
    configuration, which is public.
  EOT
}

variable "peer_ports" {
  type        = set(string)
  default     = []
  description = <<-EOT
    The WireGuard listen ports of this site's dn42 peer tunnels, one per
    peer, from the peer's port in nixos/<site>/dn42.nix. Not secrets, for
    the same reason as the carrier ports.
  EOT
}

variable "ssh_public_key" {
  type        = string
  description = <<-EOT
    Bootstrap access only: the NixOS AMI takes its root key from instance
    metadata, and the first nixos/deploy replaces it with the real user from
    nixos/modules/common.nix.
  EOT
}

variable "ssh_bootstrap_cidrs" {
  type        = list(string)
  default     = []
  description = <<-EOT
    IPv4 ranges allowed to reach SSH, for the window between the instance
    booting and Tailscale coming up on it. Empty by default: once the host
    is on the tailnet, port 22 does not need to be open to the internet.
  EOT
}

variable "instance_type" {
  type        = string
  default     = "t3.small"
  description = <<-EOT
    nixos/deploy copies a derivation to the target and realises it there, so
    this machine builds its own system rather than receiving a closure. That
    sets the floor: t3.micro's 1 GiB is not enough. Raise this for a large
    rebuild and lower it afterwards; the root volume persists.
  EOT
}
