# The inventory's hosts as known clients, so the controller shows each by
# its inventory name rather than by the hostname its DHCP request happens
# to carry. The router does the addressing, so no address or network is
# set here; a client the controller has already seen is taken over.
resource "unifi_client" "inventory" {
  for_each = toset(keys(local.mac))

  mac  = local.mac[each.key]
  name = each.key
}
