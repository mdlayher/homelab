# The wired networks, one per VLAN the switches carry, named as the router
# names its interfaces (see nixos/inventory/). The router is the gateway
# and serves every one of them, so the controller does no addressing:
# each is VLAN-only. On a segment the router hands addresses on, the
# switches drop DHCP replies from any other server.
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

  # The segments the router runs a DHCP server on: the inventory's subnets
  # (nixos/inventory/default.nix). The dn42 and lab VLANs address themselves.
  served = ["guest0", "lan0", "dev0", "iot0", "iot1"]

  # The router's address on each served segment, by the inventory's layout
  # (nixos/modules/inventory.nix): the site's /16 is the management LAN's,
  # the third octet is the VLAN id, and the router is host 1.
  site4   = format("%s/16", cidrhost(var.mgmt0_gateway4, 0))
  router4 = { for name in local.served : name => cidrhost(cidrsubnet(local.site4, 8, local.vlans[name]), 1) }
}

resource "unifi_network" "vlan" {
  for_each = local.vlans

  name                = each.key
  vlan                = each.value
  third_party_gateway = true

  dhcp_guarding = contains(local.served, each.key) ? {
    enabled = true
    servers = [local.router4[each.key]]
  } : null
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

  dhcp_guarding = {
    enabled = true
    servers = [split("/", var.mgmt0_gateway4)[0]]
  }
}
