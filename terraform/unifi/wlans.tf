# The SSIDs. The router does the addressing and keeps the networks apart,
# so a WLAN here is an SSID, its passphrase and the VLAN it bridges onto,
# served on every band by every adopted access point.

# The controller's default access point group, which holds every adopted
# access point.
data "unifi_ap_group" "default" {
  name = "All APs"
}

# The controller's default client rate group, which a WLAN must name; it
# imposes no limit.
data "unifi_client_qos_rate" "default" {
  name = "Default"
}

# The guest network's SSID: WPA3 alone, with stations kept from reaching
# one another over the air.
resource "unifi_wlan" "guest" {
  name            = "Raspberry Wild One"
  security        = "wpapsk"
  passphrase      = var.wlan_guest_passphrase
  wpa3_support    = true
  wpa3_transition = false
  pmf_mode        = "required"
  l2_isolation    = true
  network_id      = unifi_network.vlan["guest0"].id
  ap_group_ids    = [data.unifi_ap_group.default.id]
  user_group_id   = data.unifi_client_qos_rate.default.id
}
