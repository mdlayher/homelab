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

resource "aws_vpc" "pdx" {
  cidr_block = local.vpc_cidr

  # Amazon hands out a /56 here. We do not choose it and it does not matter
  # what it is: it addresses the carrier's outside, and everything we route
  # rides inside the tunnel on our own /48.
  assign_generated_ipv6_cidr_block = true

  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = local.site }
}

resource "aws_subnet" "pdx" {
  vpc_id = aws_vpc.pdx.id

  cidr_block      = local.subnet_cidr
  ipv6_cidr_block = cidrsubnet(aws_vpc.pdx.ipv6_cidr_block, 8, 0)

  tags = { Name = local.site }
}

resource "aws_internet_gateway" "pdx" {
  vpc_id = aws_vpc.pdx.id

  tags = { Name = local.site }
}

# A full internet gateway for both families rather than egress-only for IPv6:
# azo is the side that initiates, so this side has to accept an inbound
# carrier on whichever family it comes in on.
resource "aws_route_table" "pdx" {
  vpc_id = aws_vpc.pdx.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.pdx.id
  }

  route {
    ipv6_cidr_block = "::/0"
    gateway_id      = aws_internet_gateway.pdx.id
  }

  tags = { Name = local.site }
}

resource "aws_route_table_association" "pdx" {
  subnet_id      = aws_subnet.pdx.id
  route_table_id = aws_route_table.pdx.id
}

resource "aws_security_group" "pdx" {
  name        = "${local.site}-interconnect"
  description = "Site interconnect endpoint"
  vpc_id      = aws_vpc.pdx.id

  tags = { Name = local.site }
}

# The carrier itself. Open to the whole internet in both families because
# azo's WAN address is dynamic and cannot be named here; WireGuard answers
# nothing it cannot authenticate, which is what makes that acceptable.
#
# Only UDP is on the wire: the GRETAP rides inside the carrier, so no
# protocol 47 accept is needed.
resource "aws_vpc_security_group_ingress_rule" "wireguard_v4" {
  security_group_id = aws_security_group.pdx.id

  cidr_ipv4   = "0.0.0.0/0"
  from_port   = local.wireguard_port
  to_port     = local.wireguard_port
  ip_protocol = "udp"
  description = "WireGuard carrier"
}

resource "aws_vpc_security_group_ingress_rule" "wireguard_v6" {
  security_group_id = aws_security_group.pdx.id

  cidr_ipv6   = "::/0"
  from_port   = local.wireguard_port
  to_port     = local.wireguard_port
  ip_protocol = "udp"
  description = "WireGuard carrier"
}

# Path MTU discovery. Security groups are stateful for a flow, but a
# "packet too big" arrives from an intermediate router outside that flow, so
# without these rules it is dropped: large packets are then lost while small
# ones succeed. The carrier runs at MTU 1420 inside a 1500 path and depends
# on these messages.
resource "aws_vpc_security_group_ingress_rule" "pmtu_v4" {
  security_group_id = aws_security_group.pdx.id

  cidr_ipv4   = "0.0.0.0/0"
  ip_protocol = "icmp"
  from_port   = 3
  to_port     = 4
  description = "ICMP fragmentation needed, for PMTUD"
}

resource "aws_vpc_security_group_ingress_rule" "icmpv6" {
  security_group_id = aws_security_group.pdx.id

  cidr_ipv6   = "::/0"
  ip_protocol = "icmpv6"
  from_port   = -1
  to_port     = -1
  description = "ICMPv6, which IPv6 requires to function"
}

resource "aws_vpc_security_group_ingress_rule" "ssh" {
  for_each = toset(var.ssh_bootstrap_cidrs)

  security_group_id = aws_security_group.pdx.id

  cidr_ipv4   = each.value
  from_port   = 22
  to_port     = 22
  ip_protocol = "tcp"
  description = "Bootstrap SSH; see var.ssh_bootstrap_cidrs"
}

resource "aws_vpc_security_group_egress_rule" "all_v4" {
  security_group_id = aws_security_group.pdx.id

  cidr_ipv4   = "0.0.0.0/0"
  ip_protocol = "-1"
}

resource "aws_vpc_security_group_egress_rule" "all_v6" {
  security_group_id = aws_security_group.pdx.id

  cidr_ipv6   = "::/0"
  ip_protocol = "-1"
}

resource "aws_key_pair" "bootstrap" {
  key_name   = "${local.site}-bootstrap"
  public_key = local.ssh_public_key
}

resource "aws_instance" "pdx" {
  ami           = data.aws_ami.nixos.id
  instance_type = var.instance_type

  subnet_id              = aws_subnet.pdx.id
  vpc_security_group_ids = [aws_security_group.pdx.id]
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

  tags = { Name = local.site }
}

resource "aws_eip" "pdx" {
  instance = aws_instance.pdx.id
  domain   = "vpc"

  tags = { Name = local.site }
}
