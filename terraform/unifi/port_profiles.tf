# Switch port profiles. A profile names the untagged network and which
# others a port carries; ports are assigned profiles in the UI.
#
# Every block_all profile sets forward = "native" explicitly: left to the
# controller, the create fails with an inconsistent result.
#
# Every profile runs STP on its ports. Left unset, the profiles landed on
# the controller with it off, so the switch uplinks ran no STP at all.

# Every network: mgmt0 untagged, everything else tagged. For the router's
# trunk, the room switches' uplinks and the access points.
resource "unifi_port_profile" "trunk" {
  name                  = "trunk"
  native_networkconf_id = unifi_network.mgmt0.id
  forward               = "all"
  tagged_vlan_mgmt      = "auto"
  stp_port_mode         = true
}

# No host at all. The controller's disabled port state is a MAC filter
# admitting no address; forwarding set to disabled on its own leaves the
# port active. The controller clears the native network of such a profile.
resource "unifi_port_profile" "disabled" {
  name                      = "disabled"
  native_networkconf_id     = ""
  forward                   = "disabled"
  port_security_enabled     = true
  port_security_mac_address = []
  stp_port_mode             = true
}

# The management LAN alone, for the rack devices that manage over it.
resource "unifi_port_profile" "mgmt0" {
  name                  = "mgmt0"
  native_networkconf_id = unifi_network.mgmt0.id
  forward               = "native"
  tagged_vlan_mgmt      = "block_all"
  stp_port_mode         = true
}

# The IS-IS lab link to lasthop alone, untagged, for a port given over to
# it.
resource "unifi_port_profile" "lasthop_isis" {
  name                  = "lasthop-isis"
  native_networkconf_id = unifi_network.vlan["lasthop-isis"].id
  forward               = "native"
  tagged_vlan_mgmt      = "block_all"
  stp_port_mode         = true
}

# Kept through the switch update, since the controller refuses to delete a
# profile a port still carries; removed in the apply that follows.
resource "unifi_port_profile" "server" {
  name                  = "server"
  native_networkconf_id = ""
  forward               = "customize"
  tagged_vlan_mgmt      = "custom"
  excluded_networkconf_ids = concat([unifi_network.mgmt0.id], [
    for name, n in unifi_network.vlan : n.id
    if !contains(["dev0", "dn42", "lasthop-isis"], name)
  ])
  stp_port_mode = true
}
