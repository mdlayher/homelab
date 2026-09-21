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

  carrier_ports = ["51120", "51121", "51230"]

  ssh_public_key      = local.ssh_public_key
  ssh_bootstrap_cidrs = lookup(var.ssh_bootstrap_cidrs, "pdx", [])
  instance_type       = lookup(var.instance_types, "pdx", "t3.small")
}

# Which zones in this region offer the instance type, since not all of them
# do: us-east-1e has no t3, and a subnet with no zone is placed by AWS
# wherever it likes -- the instance then fails to launch in a zone that
# cannot hold it. Asked rather than named, so the answer stays true when the
# type or the region changes. pdx names no zone: it was placed before this
# existed, and naming one now would replace its subnet and its instance.
data "aws_ec2_instance_type_offerings" "iad" {
  provider = aws.iad

  location_type = "availability-zone"

  filter {
    name   = "instance-type"
    values = [local.iad_instance_type]
  }
}

module "iad" {
  source    = "./modules/site"
  providers = { aws = aws.iad }

  site        = "iad"
  vpc_cidr    = "10.81.0.0/16"
  subnet_cidr = "10.81.0.0/24"

  # Sorted so the choice is stable across plans rather than following
  # whatever order the API answered in.
  availability_zone = sort(data.aws_ec2_instance_type_offerings.iad.locations)[0]

  carrier_ports = ["51130", "51131", "51230"]

  ssh_public_key      = local.ssh_public_key
  ssh_bootstrap_cidrs = lookup(var.ssh_bootstrap_cidrs, "iad", [])
  instance_type       = local.iad_instance_type
}
