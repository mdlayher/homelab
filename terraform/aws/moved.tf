# pdx was built when this root module was the site. These record where each
# of its objects went when the site became a module, so the next plan moves
# them in state rather than proposing to destroy and recreate them. Applying
# a destroy here would take the EIP and the instance with it.
#
# Removable once applied, but they cost nothing and they are the only record
# of where pdx came from.

moved {
  from = aws_vpc.pdx
  to   = module.pdx.aws_vpc.this
}

moved {
  from = aws_subnet.pdx
  to   = module.pdx.aws_subnet.this
}

moved {
  from = aws_internet_gateway.pdx
  to   = module.pdx.aws_internet_gateway.this
}

moved {
  from = aws_route_table.pdx
  to   = module.pdx.aws_route_table.this
}

moved {
  from = aws_route_table_association.pdx
  to   = module.pdx.aws_route_table_association.this
}

moved {
  from = aws_security_group.pdx
  to   = module.pdx.aws_security_group.this
}

# The carrier rules were one resource per port and family; they are now one
# resource per family, keyed by port.
moved {
  from = aws_vpc_security_group_ingress_rule.wireguard_v4
  to   = module.pdx.aws_vpc_security_group_ingress_rule.carrier_v4["51120"]
}

moved {
  from = aws_vpc_security_group_ingress_rule.wireguard_v6
  to   = module.pdx.aws_vpc_security_group_ingress_rule.carrier_v6["51120"]
}

moved {
  from = aws_vpc_security_group_ingress_rule.wireguard_plane1_v4
  to   = module.pdx.aws_vpc_security_group_ingress_rule.carrier_v4["51121"]
}

moved {
  from = aws_vpc_security_group_ingress_rule.wireguard_plane1_v6
  to   = module.pdx.aws_vpc_security_group_ingress_rule.carrier_v6["51121"]
}

# These keep their own for_each keys, so the whole resource moves with its
# instances.
moved {
  from = aws_vpc_security_group_ingress_rule.page_v4
  to   = module.pdx.aws_vpc_security_group_ingress_rule.page_v4
}

moved {
  from = aws_vpc_security_group_ingress_rule.page_v6
  to   = module.pdx.aws_vpc_security_group_ingress_rule.page_v6
}

moved {
  from = aws_vpc_security_group_ingress_rule.pmtu_v4
  to   = module.pdx.aws_vpc_security_group_ingress_rule.pmtu_v4
}

moved {
  from = aws_vpc_security_group_ingress_rule.icmpv6
  to   = module.pdx.aws_vpc_security_group_ingress_rule.icmpv6
}

moved {
  from = aws_vpc_security_group_ingress_rule.ssh
  to   = module.pdx.aws_vpc_security_group_ingress_rule.ssh
}

moved {
  from = aws_vpc_security_group_egress_rule.all_v4
  to   = module.pdx.aws_vpc_security_group_egress_rule.all_v4
}

moved {
  from = aws_vpc_security_group_egress_rule.all_v6
  to   = module.pdx.aws_vpc_security_group_egress_rule.all_v6
}

moved {
  from = aws_key_pair.bootstrap
  to   = module.pdx.aws_key_pair.bootstrap
}

moved {
  from = aws_instance.pdx
  to   = module.pdx.aws_instance.this
}

moved {
  from = aws_eip.pdx
  to   = module.pdx.aws_eip.this
}
