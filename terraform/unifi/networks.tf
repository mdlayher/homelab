# The wired networks, one per VLAN the switches carry, named as the router
# names its interfaces (see nixos/inventory/). The router is the gateway
# and serves every one of them, so the controller does no addressing:
# each is VLAN-only.
locals {
  vlans = {
    guest0       = 9
    lan0         = 10
    dev0         = 20
    dn42         = 42
    iot0         = 66
    iot1         = 67
    lasthop-isis = 131
  }
}

resource "unifi_network" "vlan" {
  for_each = local.vlans

  name                = each.key
  vlan                = each.value
  third_party_gateway = true
}

# The management LAN, untagged, which the controller's built-in Default
# network already is: switches and access points manage over it. Adopted
# into the state rather than created (see nixos/servnerr-4/unifi.nix).
# Its purpose cannot be changed from corporate, which requires a subnet;
# the controller's DHCP server stays off. Under the automatic setting
# preference the controller turns that server back on, so the preference
# is manual. The controller still checks the server's range against the
# subnet, so the range is the subnet's hosts, never served.
resource "unifi_network" "mgmt0" {
  name    = "mgmt0"
  purpose = "corporate"
  subnet  = var.mgmt0_gateway4

  setting_preference = "manual"

  dhcp_server = {
    enabled = false
    start   = cidrhost(var.mgmt0_gateway4, 2)
    stop    = cidrhost(var.mgmt0_gateway4, -2)
  }
}
