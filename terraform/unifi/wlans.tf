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

# The lowest 2.4 GHz rate the SSIDs carry, which sets the rate of their
# beacons and management frames. The band is busy with the neighbours'
# networks, and the legacy rates below 6 Mbps serve 802.11b devices alone.
locals {
  min_rate_2g_kbps = 6000
}

# The LAN's SSID: WPA3 alone, with management frame protection required.
# Every SSID but the legacy one tells a roaming client about the
# neighbouring access points. 802.11r and multi-link stay off: pushing
# them hung the access points' management agents on firmware 8.7.11.
resource "unifi_wlan" "lan" {
  name                       = "Black Note Stout"
  security                   = "wpapsk"
  passphrase                 = var.wlan_lan_passphrase
  wpa3_support               = true
  wpa3_transition            = false
  pmf_mode                   = "required"
  minrate_setting_preference = "manual"
  minimum_data_rate_2g_kbps  = local.min_rate_2g_kbps
  bss_transition             = true
  network_id                 = unifi_network.vlan["lan0"].id
  ap_group_ids               = [data.unifi_ap_group.default.id]
  user_group_id              = data.unifi_client_qos_rate.default.id
}

# The guest network's SSID: WPA3 with WPA2 alongside for the devices that
# speak only that, and stations kept from reaching one another over the
# air.
resource "unifi_wlan" "guest" {
  name                       = "Raspberry Wild One"
  security                   = "wpapsk"
  passphrase                 = var.wlan_guest_passphrase
  wpa3_support               = true
  wpa3_transition            = true
  pmf_mode                   = "optional"
  l2_isolation               = true
  minrate_setting_preference = "manual"
  minimum_data_rate_2g_kbps  = local.min_rate_2g_kbps
  bss_transition             = true
  network_id                 = unifi_network.vlan["guest0"].id
  ap_group_ids               = [data.unifi_ap_group.default.id]
  user_group_id              = data.unifi_client_qos_rate.default.id
}

# The IoT SSIDs: WPA2 alongside WPA3, since most of the devices speak only
# WPA2, with management frame protection optional for the same reason. A
# WPA2 SSID cannot be offered on 6 GHz.
locals {
  iot_wlans = {
    iot  = { name = "MDL IoT", network = "iot0", passphrase = var.wlan_iot_passphrase }
    iot1 = { name = "MDL IoT1", network = "iot1", passphrase = var.wlan_iot1_passphrase }
  }
}

resource "unifi_wlan" "iot" {
  for_each = local.iot_wlans

  name                       = each.value.name
  security                   = "wpapsk"
  passphrase                 = each.value.passphrase
  wpa3_support               = true
  wpa3_transition            = true
  pmf_mode                   = "optional"
  minrate_setting_preference = "manual"
  minimum_data_rate_2g_kbps  = local.min_rate_2g_kbps
  bss_transition             = true
  network_id                 = unifi_network.vlan[each.value.network].id
  ap_group_ids               = [data.unifi_ap_group.default.id]
  user_group_id              = data.unifi_client_qos_rate.default.id
}
