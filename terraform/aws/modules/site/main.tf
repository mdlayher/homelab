# One site: a VPC holding a single dual-stack host which terminates the
# WireGuard carriers of the circuits reaching it, and routes for our AS.
# Everything here is the site rather than the machine, which is why nothing
# in this module names one: the NixOS configuration lives in nixos/edge-<site>
# and arrives by nixos/deploy, and a machine rename costs no terraform state.
#
# The region is not an input: the root passes a provider configured for it,
# so a site cannot disagree with itself about where it is.

# The NixOS AMI. 427812963091 is the NixOS project's own AWS account, and
# querying by name is what upstream recommends rather than pinning an id:
# images are published weekly to every region and garbage collected after 90
# days, so a pinned id stops resolving within a quarter.
#
# The release tracks flake.nix's nixpkgs input (nixos-26.05). The running
# system comes from nixos/deploy regardless of which AMI the instance booted
# from, but a rebuilt instance starts from whatever this names, so keep the
# two together.
data "aws_ami" "nixos" {
  owners      = ["427812963091"]
  most_recent = true

  filter {
    name   = "name"
    values = ["nixos/26.05*"]
  }

  # Architecture is its own filter; it is not encoded in the image name.
  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

resource "aws_vpc" "this" {
  cidr_block = var.vpc_cidr

  # Amazon hands out a /56 here. We do not choose it and it does not matter
  # what it is: it addresses the carrier's outside, and everything we route
  # rides inside the tunnel on our own /48.
  assign_generated_ipv6_cidr_block = true

  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = var.site }
}

resource "aws_subnet" "this" {
  vpc_id = aws_vpc.this.id

  cidr_block        = var.subnet_cidr
  ipv6_cidr_block   = cidrsubnet(aws_vpc.this.ipv6_cidr_block, 8, 0)
  availability_zone = var.availability_zone

  tags = { Name = var.site }

  # The zone is chosen once, at creation. A subnet cannot move, so a
  # different value later would replace it and the instance inside it;
  # ignoring the attribute makes that impossible, and the postcondition
  # makes a pin that disagrees with the subnet a plan failure naming the
  # real zone rather than a silent lie.
  lifecycle {
    ignore_changes = [availability_zone]

    postcondition {
      condition     = var.availability_zone == null || self.availability_zone == var.availability_zone
      error_message = "subnet ${var.site} is in ${self.availability_zone}, not the pinned ${var.availability_zone}; pin the zone it is in"
    }
  }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = { Name = var.site }
}

# A full internet gateway for both families rather than egress-only for IPv6:
# a site whose carriers are dialled from elsewhere has to accept an inbound
# carrier on whichever family it comes in on.
resource "aws_route_table" "this" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  route {
    ipv6_cidr_block = "::/0"
    gateway_id      = aws_internet_gateway.this.id
  }

  tags = { Name = var.site }
}

resource "aws_route_table_association" "this" {
  subnet_id      = aws_subnet.this.id
  route_table_id = aws_route_table.this.id
}

resource "aws_security_group" "this" {
  name        = "${var.site}-interconnect"
  description = "Site interconnect endpoint"
  vpc_id      = aws_vpc.this.id

  tags = { Name = var.site }
}

# The carriers themselves, one rule per port per family. Open to the whole
# internet in both families because a dialling site's WAN address may be
# dynamic and cannot be named here; WireGuard answers nothing it cannot
# authenticate, which is what makes that acceptable.
#
# Only UDP is on the wire: the GRETAP rides inside the carrier, so no
# protocol 47 accept is needed.
#
# for_each is keyed on the port, so adding a circuit adds a rule and never
# destroys the one admitting an existing circuit. A count or a list index
# would not hold that property.
resource "aws_vpc_security_group_ingress_rule" "carrier_v4" {
  for_each = var.carrier_ports

  security_group_id = aws_security_group.this.id

  cidr_ipv4   = "0.0.0.0/0"
  from_port   = tonumber(each.key)
  to_port     = tonumber(each.key)
  ip_protocol = "udp"
  description = "WireGuard carrier"
}

resource "aws_vpc_security_group_ingress_rule" "carrier_v6" {
  for_each = var.carrier_ports

  security_group_id = aws_security_group.this.id

  cidr_ipv6   = "::/0"
  from_port   = tonumber(each.key)
  to_port     = tonumber(each.key)
  ip_protocol = "udp"
  description = "WireGuard carrier"
}

# The interconnect landing page (see nixos/modules/icl-page.nix). Port 80
# also carries the HTTP-01 challenge that certifies it, which is why the
# certificate needs no Cloudflare credential on a machine reachable from
# the internet. Open in both families because the names it answers for are
# public and resolve to this host in both.
#
# The only TCP ports open here: everything else this machine answers is
# reached over the tailnet or a circuit. What is served is a static page
# and nothing else; see the host firewall in nixos/edge-<site>.
resource "aws_vpc_security_group_ingress_rule" "page_v4" {
  for_each = toset(["80", "443"])

  security_group_id = aws_security_group.this.id

  cidr_ipv4   = "0.0.0.0/0"
  from_port   = tonumber(each.key)
  to_port     = tonumber(each.key)
  ip_protocol = "tcp"
  description = "Interconnect page"
}

resource "aws_vpc_security_group_ingress_rule" "page_v6" {
  for_each = toset(["80", "443"])

  security_group_id = aws_security_group.this.id

  cidr_ipv6   = "::/0"
  from_port   = tonumber(each.key)
  to_port     = tonumber(each.key)
  ip_protocol = "tcp"
  description = "Interconnect page"
}

# Path MTU discovery. Security groups are stateful for a flow, but a
# "packet too big" arrives from an intermediate router outside that flow, so
# without these rules it is dropped: large packets are then lost while small
# ones succeed. The carrier runs at MTU 1420 inside a 1500 path and depends
# on these messages.
resource "aws_vpc_security_group_ingress_rule" "pmtu_v4" {
  security_group_id = aws_security_group.this.id

  cidr_ipv4   = "0.0.0.0/0"
  ip_protocol = "icmp"
  from_port   = 3
  to_port     = 4
  description = "ICMP fragmentation needed, for PMTUD"
}

resource "aws_vpc_security_group_ingress_rule" "icmpv6" {
  security_group_id = aws_security_group.this.id

  cidr_ipv6   = "::/0"
  ip_protocol = "icmpv6"
  from_port   = -1
  to_port     = -1
  description = "ICMPv6, which IPv6 requires to function"
}

resource "aws_vpc_security_group_ingress_rule" "ssh" {
  for_each = toset(var.ssh_bootstrap_cidrs)

  security_group_id = aws_security_group.this.id

  cidr_ipv4   = each.value
  from_port   = 22
  to_port     = 22
  ip_protocol = "tcp"
  description = "Bootstrap SSH; see var.ssh_bootstrap_cidrs"
}

resource "aws_vpc_security_group_egress_rule" "all_v4" {
  security_group_id = aws_security_group.this.id

  cidr_ipv4   = "0.0.0.0/0"
  ip_protocol = "-1"
}

resource "aws_vpc_security_group_egress_rule" "all_v6" {
  security_group_id = aws_security_group.this.id

  cidr_ipv6   = "::/0"
  ip_protocol = "-1"
}

resource "aws_key_pair" "bootstrap" {
  key_name   = "${var.site}-bootstrap"
  public_key = var.ssh_public_key
}

resource "aws_instance" "this" {
  ami           = data.aws_ami.nixos.id
  instance_type = var.instance_type

  subnet_id              = aws_subnet.this.id
  vpc_security_group_ids = [aws_security_group.this.id]
  key_name               = aws_key_pair.bootstrap.key_name
  ipv6_address_count     = 1

  # This host forwards packets that are neither from nor to it, which EC2
  # drops by default. Without this the carrier comes up and the IS-IS
  # adjacency forms while no traffic routes.
  source_dest_check = false

  root_block_device {
    volume_type = "gp3"
    volume_size = 30
    encrypted   = true
  }

  # Replacing the instance rebuilds it from an AMI. The system configuration
  # comes from this repository, but the host's SSH key does not, and the sops
  # recipient is derived from that key: a replacement needs ssh-to-age and
  # updatekeys again before it can decrypt anything.
  lifecycle {
    ignore_changes = [ami]
  }

  tags = { Name = var.site }
}

resource "aws_eip" "this" {
  instance = aws_instance.this.id
  domain   = "vpc"

  tags = { Name = var.site }
}
