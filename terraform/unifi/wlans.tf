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

# The guest network's SSID: WPA3 with WPA2 alongside for the devices that
# speak only that, and stations kept from reaching one another over the
# air.
resource "unifi_wlan" "guest" {
  name            = "Raspberry Wild One"
  security        = "wpapsk"
  passphrase      = var.wlan_guest_passphrase
  wpa3_support    = true
  wpa3_transition = true
  pmf_mode        = "optional"
  l2_isolation    = true
  network_id      = unifi_network.vlan["guest0"].id
  ap_group_ids    = [data.unifi_ap_group.default.id]
  user_group_id   = data.unifi_client_qos_rate.default.id
}

# The IoT SSIDs: WPA2 alongside WPA3, since most of the devices speak only
# WPA2, and on iot0 a second SSID with WPA2 alone, management frame
# protection off and the controller's IoT tuning, for devices that refuse
# an SSID with WPA3 in its beacon. A WPA2 SSID cannot be offered on 6 GHz.
locals {
  iot_wlans = {
    iot  = { name = "MDL IoT", network = "iot0", passphrase = var.wlan_iot_passphrase, wpa3 = true, wpa2 = true }
    iot1 = { name = "MDL IoT1", network = "iot1", passphrase = var.wlan_iot1_passphrase, wpa3 = true, wpa2 = true }
    iot2 = { name = "MDL IoT2", network = "iot0", passphrase = var.wlan_iot2_passphrase, wpa3 = false, wpa2 = true }
  }
}

resource "unifi_wlan" "iot" {
  for_each = local.iot_wlans

  name            = each.value.name
  security        = "wpapsk"
  passphrase      = each.value.passphrase
  wpa3_support    = each.value.wpa3
  wpa3_transition = each.value.wpa3 && each.value.wpa2
  pmf_mode        = !each.value.wpa3 ? "disabled" : each.value.wpa2 ? "optional" : "required"
  enhanced_iot    = !each.value.wpa3
  wlan_bands      = each.value.wpa3 ? null : ["2g", "5g"]
  network_id      = unifi_network.vlan[each.value.network].id
  ap_group_ids    = [data.unifi_ap_group.default.id]
  user_group_id   = data.unifi_client_qos_rate.default.id
}
