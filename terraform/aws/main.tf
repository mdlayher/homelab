# The sites. One module call each rather than a for_each, because a site is
# pinned to a region and a provider cannot be selected dynamically.
#
# Carrier ports are 51<a><b><plane> from the two sites' indices in ascending
# order, derived identically by nixos/modules/interconnect.nix at both ends.
# azo is site 01, pdx 02, iad 03, so azo-pdx is 51120 and 51121, azo-iad is
# 51130 and 51131, and pdx-iad is 51230. Each site opens the ports of every
# circuit that ends on it, whichever end dials.

module "pdx" {
  source = "./modules/site"

  site        = "pdx"
  vpc_cidr    = "10.80.0.0/16"
  subnet_cidr = "10.80.0.0/24"

  # The zone this site was placed in, read from its instance metadata; the
  # module refuses a pin that disagrees with the subnet rather than moving
  # it.
  availability_zone = "us-west-2a"

  carrier_ports = ["51120", "51121", "51230"]

  ssh_public_key      = local.ssh_public_key
  ssh_bootstrap_cidrs = lookup(var.ssh_bootstrap_cidrs, "pdx", [])
  instance_type       = lookup(var.instance_types, "pdx", "t3.small")
}

# Each site names the zone it is in. Not every zone offers every instance
# type (us-east-1e has no t3), and a subnet with no zone is placed by AWS
# wherever it likes, so a new site names one that offers its type before
# the first apply. After that the pin is a record: the module refuses one
# that disagrees with the subnet rather than moving it.
module "iad" {
  source    = "./modules/site"
  providers = { aws = aws.iad }

  site        = "iad"
  vpc_cidr    = "10.81.0.0/16"
  subnet_cidr = "10.81.0.0/24"

  availability_zone = "us-east-1a"

  carrier_ports = ["51130", "51131", "51230"]

  ssh_public_key      = local.ssh_public_key
  ssh_bootstrap_cidrs = lookup(var.ssh_bootstrap_cidrs, "iad", [])
  instance_type       = lookup(var.instance_types, "iad", "t3.small")
}
