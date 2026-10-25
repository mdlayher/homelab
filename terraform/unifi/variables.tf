# The management LAN's IPv4 gateway address and prefix length, such as
# 192.0.2.1/24, from secrets/unifi.yaml as TF_VAR_mgmt0_gateway4. The
# controller requires one on its built-in network (see networks.tf) and
# refuses the network address in its place; the router serves the LAN, so
# nothing here uses it.
variable "mgmt0_gateway4" {
  type      = string
  sensitive = true

  validation {
    condition     = split("/", var.mgmt0_gateway4)[0] != cidrhost(var.mgmt0_gateway4, 0)
    error_message = "mgmt0_gateway4 must be the gateway's address with the prefix length, not the network address."
  }
}

# The guest SSID's passphrase (see wlans.tf), from secrets/unifi.yaml as
# TF_VAR_wlan_guest_passphrase.
variable "wlan_guest_passphrase" {
  type      = string
  sensitive = true
}
