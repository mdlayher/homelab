# What the other end needs to configure the circuit. The v4 address goes in
# homelab.interconnect.links.pdx.endpoint at azo: azo initiates, because
# its WAN address changes and this one does not.
output "endpoint_v4" {
  value       = aws_eip.pdx.public_ip
  description = "Stable IPv4 for the WireGuard carrier's endpoint."
}

output "endpoint_v6" {
  value       = one(aws_instance.pdx.ipv6_addresses)
  description = "IPv6 for the WireGuard carrier, if preferred over v4."
}

output "instance_id" {
  value       = aws_instance.pdx.id
  description = "For the console and for EC2 serial access when SSH is gone."
}
