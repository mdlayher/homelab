# Every named address as a known client, so the controller shows it by
# name. The router does the addressing, so no address or network is set
# here; a client the controller has already seen is taken over.
resource "unifi_client" "inventory" {
  for_each = merge(local.mac, local.extra)

  mac  = each.value
  name = each.key
}
