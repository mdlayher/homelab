# What the other end needs to configure a circuit, and what
# terraform/cloudflare publishes by hand as <family>.<site>.icl. The v4
# address goes in homelab.interconnect.links.<site>.endpoint at the site
# which dials: the dialling end is the one whose address may change.
output "pdx_endpoint_v4" {
  value       = module.pdx.endpoint_v4
  description = "Stable IPv4 for pdx's WireGuard carriers."
}

output "pdx_endpoint_v6" {
  value       = module.pdx.endpoint_v6
  description = "IPv6 for pdx's WireGuard carriers."
}

output "pdx_instance_id" {
  value       = module.pdx.instance_id
  description = "For the console and for EC2 serial access when SSH is gone."
}

output "iad_endpoint_v4" {
  value       = module.iad.endpoint_v4
  description = "Stable IPv4 for iad's WireGuard carriers."
}

output "iad_endpoint_v6" {
  value       = module.iad.endpoint_v6
  description = "IPv6 for iad's WireGuard carriers."
}

output "iad_instance_id" {
  value       = module.iad.instance_id
  description = "For the console and for EC2 serial access when SSH is gone."
}
