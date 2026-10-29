# The switches and access points. The controller adopts a device in the
# UI; it then enters the state through an import by its MAC
# (sops-gate tofu-import unifi unifi_device.<name> <mac>), so no MAC is
# written here. A port a device lists takes the named profile or states
# its settings itself; a port with nothing cabled to it takes the disabled
# profile.

# The rack's core switch. Devices in the rack fill the copper ports from
# port 1 up; runs to the rest of the house and the uplinks to other
# switches fill them from port 22 down, so the two groups meet in the
# free middle. The SFP+ cages hold the router and the server.
locals {
  # Core ports locked to one host each, by port index: the port's label,
  # the host whose hardware address alone may use it, and the network the
  # port carries untagged. A trunk carries every other network tagged as
  # well; any other port blocks tagged frames.
  locked = {
    1 = { name = "kvm", host = "pikvm", network = "mgmt0" }
    2 = { name = "server 1g", host = "servnerr-4", network = "mgmt0" }
    3 = { name = "jump", host = "jumpnerr-1", network = "mgmt0" }
    4 = { name = "hass", host = "hass", network = "mgmt0" }
    5 = { name = "pdu01", host = "pdu01", network = "mgmt0" }
    6 = { name = "ups01", host = "ups01", network = "mgmt0" }
    7 = { name = "hue hub", host = "server-rack-hue-hub", network = "iot0" }
    # The router's LAN port, as its networking.nix expects it: mgmt0
    # untagged with every VLAN tagged.
    25 = { name = "router", host = "routnerr-3", network = "mgmt0", trunk = true }
  }

  # Office ports, by index: the port's label and the network it carries
  # untagged, blocking tagged frames. The office switch cannot restrict a
  # port by hardware address (its specifications list no such feature, and
  # a port set that way passed another host), so no host is named.
  office = {
    1 = { name = "workstation", network = "mgmt0" }
    2 = { name = "gaming pc", network = "lan0" }
    3 = { name = "office printer", network = "iot0" }
  }

  # Living room ports, by index, as the office ones. The switch is the PoE
  # model: the core powers it over its uplink and it powers the living
  # room access point on port 8.
  living_room = {
    1 = { name = "htpc", network = "lan0" }
    2 = { name = "tv streamer", network = "iot0" }
    3 = { name = "playstation", network = "guest0" }
    4 = { name = "switch 2", network = "guest0" }
    5 = { name = "av receiver", network = "iot0" }
  }

  # Each access point's fixed channels. On 2.4 GHz, access points that
  # hear each other never share a channel. On 5 GHz each has its own
  # 40 MHz block outside the radar channels. 6 GHz is the controller's
  # choice.
  ap_channels = {
    ap_living_room  = { ng = 1, na = 36 }
    ap_basement     = { ng = 6, na = 44 }
    ap_laundry_room = { ng = 11, na = 149 }
  }
  radios = {
    for name, ch in local.ap_channels : name => [
      { radio = "ng", channel = tostring(ch.ng), ht = 20, tx_power_mode = "auto" },
      { radio = "na", channel = tostring(ch.na), ht = 40, tx_power_mode = "auto" },
      { radio = "6e", channel = "auto", ht = 160, tx_power_mode = "auto" },
    ]
  }

  # Ports with nothing cabled to them, per switch and by index.
  disabled = {
    core        = concat(range(8, 19), [23, 24, 26, 28])
    office      = concat(range(4, 9), [10])
    living_room = concat(range(6, 8), [10])
  }

  # Network name to controller id, for the locked ports.
  network_id = merge(
    { mgmt0 = unifi_network.mgmt0.id },
    { for name, network in unifi_network.vlan : name => network.id },
  )
}

resource "unifi_device" "switch_core" {
  name = "switch-core"

  # A port with a profile takes every setting from it and the controller
  # discards the port's own, a MAC filter included, so a locked port
  # carries no profile and states its settings itself.
  dynamic "port_override" {
    for_each = local.locked
    content {
      index                     = tonumber(port_override.key)
      name                      = port_override.value.name
      setting_preference        = "manual"
      native_networkconf_id     = local.network_id[port_override.value.network]
      tagged_vlan_mgmt          = try(port_override.value.trunk, false) ? "auto" : "block_all"
      forward                   = try(port_override.value.trunk, false) ? "all" : "native"
      port_security_enabled     = true
      port_security_mac_address = [local.mac[port_override.value.host]]
    }
  }

  dynamic "port_override" {
    for_each = toset(local.disabled.core)
    content {
      index           = port_override.value
      name            = "unused"
      port_profile_id = unifi_port_profile.disabled.id
    }
  }

  # The living room switch's uplink, which also powers it.
  port_override {
    index           = 19
    name            = "switch-living-room"
    port_profile_id = unifi_port_profile.trunk.id
  }

  port_override {
    index           = 20
    name            = "ap-basement"
    port_profile_id = unifi_port_profile.trunk.id
  }

  port_override {
    index           = 21
    name            = "ap-laundry-room"
    port_profile_id = unifi_port_profile.trunk.id
  }

  port_override {
    index           = 22
    name            = "switch-office"
    port_profile_id = unifi_port_profile.trunk.id
  }

  # The server's 10G port; see the server profile.
  port_override {
    index           = 27
    name            = "server 10g"
    port_profile_id = unifi_port_profile.server.id
  }
}

# The basement access point. Its trunk is core port 20, above.
resource "unifi_device" "ap_basement" {
  name        = "ap-basement"
  radio_table = local.radios.ap_basement
}

# The living room access point, on the living room switch's port 8,
# which powers it.
resource "unifi_device" "ap_living_room" {
  name        = "ap-living-room"
  radio_table = local.radios.ap_living_room
}

# The laundry room access point. Its trunk is core port 21, above.
resource "unifi_device" "ap_laundry_room" {
  name        = "ap-laundry-room"
  radio_table = local.radios.ap_laundry_room
}

# The office switch, on the run from core port 22 into its 10GBASE-T port.
# Both ends of the run are trunks, so a port here can carry any network.
# Disabled ports as on the core, above.
resource "unifi_device" "switch_office" {
  name = "switch-office"

  port_override {
    index           = 9
    name            = "switch-core"
    port_profile_id = unifi_port_profile.trunk.id
  }

  dynamic "port_override" {
    for_each = local.office
    content {
      index                 = tonumber(port_override.key)
      name                  = port_override.value.name
      setting_preference    = "manual"
      native_networkconf_id = local.network_id[port_override.value.network]
      tagged_vlan_mgmt      = "block_all"
      forward               = "native"
    }
  }

  dynamic "port_override" {
    for_each = toset(local.disabled.office)
    content {
      index           = port_override.value
      name            = "unused"
      port_profile_id = unifi_port_profile.disabled.id
    }
  }
}

# The living room switch, on the run from core port 19 into its 10GBASE-T
# port, the one port that takes PoE in: the core powers the switch and the
# access point behind it over that run. Both ends of the run are trunks,
# so a port here can carry any network. Disabled ports as on the core,
# above.
resource "unifi_device" "switch_living_room" {
  name = "switch-living-room"

  port_override {
    index           = 9
    name            = "switch-core"
    port_profile_id = unifi_port_profile.trunk.id
  }

  port_override {
    index           = 8
    name            = "ap-living-room"
    port_profile_id = unifi_port_profile.trunk.id
  }

  dynamic "port_override" {
    for_each = local.living_room
    content {
      index                 = tonumber(port_override.key)
      name                  = port_override.value.name
      setting_preference    = "manual"
      native_networkconf_id = local.network_id[port_override.value.network]
      tagged_vlan_mgmt      = "block_all"
      forward               = "native"
    }
  }

  dynamic "port_override" {
    for_each = toset(local.disabled.living_room)
    content {
      index           = port_override.value
      name            = "unused"
      port_profile_id = unifi_port_profile.disabled.id
    }
  }
}
