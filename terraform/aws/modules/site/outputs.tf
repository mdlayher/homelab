# What the other end of a circuit needs to dial this site, and what the
# Cloudflare module publishes as <family>.<site>.icl.
output "endpoint_v4" {
  value       = aws_eip.this.public_ip
  description = "Stable IPv4 for the WireGuard carriers' endpoint."
}

output "endpoint_v6" {
  value       = one(aws_instance.this.ipv6_addresses)
  description = "IPv6 for the WireGuard carriers, if preferred over v4."
}

output "instance_id" {
  value       = aws_instance.this.id
  description = "For the console and for EC2 serial access when SSH is gone."
}
