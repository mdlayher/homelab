# The switches and access points. The controller adopts a device in the
# UI; it then enters the state through an import by its MAC
# (sops-gate tofu-import unifi unifi_device.<name> <mac>), so no MAC is
# written here. A port a device lists takes the named profile or states
# its settings itself; a port with nothing cabled to it takes the disabled
# profile.

# The rack's core switch. Devices in the rack fill the 2.5 Gbit copper
# ports from port 1 up. The router's standby copper link takes the
# highest of them, and runs to the rest of the house and the uplinks to
# other switches fill the rest from below it, so the two groups meet in
# the free middle. Ports 23 and 24, the 10 Gbit copper ports, are
# reserved for 10 Gbit copper links. The SFP+ cages hold the router and
# the server.
locals {
  # Core ports locked to one host each, by port index: the port's label,
  # the host whose hardware address alone may use it, and the network it
  # carries untagged. trunk carries every other network tagged, tagged
  # names the networks carried tagged, and otherwise tagged frames are
  # blocked. A new host's port opens without a lock so the host can take
  # the lease the inventory records; the lock follows. extra_macs admits a
  # host's other addresses.
  locked = {
    1 = { name = "kvm", host = "pikvm", network = "mgmt0" }
    # The server's bond standby: mgmt0 untagged, the container VLANs
    # tagged. No lock: the port carries the bridged containers' addresses
    # beside the host's.
    2 = {
      name    = "server 1g"
      network = "mgmt0"
      tagged  = ["dev0", "dn42", "lasthop-isis"]
    }
    3 = { name = "jump", host = "jumpnerr-1", network = "mgmt0" }
    4 = { name = "hass", host = "hass", network = "mgmt0" }
    5 = { name = "pdu01", host = "pdu01", network = "mgmt0" }
    6 = { name = "ups01", host = "ups01", network = "mgmt0" }
    7 = { name = "hue hub", host = "server-rack-hue-hub", network = "iot0" }
    8 = { name = "pdu02", host = "pdu02", network = "mgmt0" }
    9 = { name = "3d printer", host = "prusa-core-one", network = "iot0" }
    # The router's bond standby. Its LLDP leaves from the port's own MAC.
    22 = {
      name       = "router 1g"
      host       = "routnerr-3"
      network    = "mgmt0"
      trunk      = true
      extra_macs = [local.extra["routnerr-3 1g"]]
    }
    # The router's bond primary, its SFP+ port: mgmt0 untagged, every
    # VLAN tagged.
    25 = { name = "router 10g", host = "routnerr-3", network = "mgmt0", trunk = true }
    # The server's bond primary, its SFP+ port: the same networks as its
    # standby, and no lock for the same reason.
    27 = {
      name    = "server 10g"
      network = "mgmt0"
      tagged  = ["dev0", "dn42", "lasthop-isis"]
    }
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
  # hear each other never share a channel; with more access points than
  # channels, the pair furthest apart shares one. On 5 GHz each has its
  # own 40 MHz block outside the radar channels. On 6 GHz each has its
  # own 160 MHz block, named by its preferred scanning channel.
  ap_channels = {
    ap_living_room  = { ng = 1, na = 36, "6e" = 69 }
    ap_basement     = { ng = 6, na = 44, "6e" = 37 }
    ap_laundry_room = { ng = 11, na = 149, "6e" = 101 }
    ap_movie_room   = { ng = 11, na = 157, "6e" = 197 }
  }
  radios = {
    for name, ch in local.ap_channels : name => [
      { radio = "ng", channel = tostring(ch.ng), ht = 20, tx_power_mode = "auto" },
      { radio = "na", channel = tostring(ch.na), ht = 40, tx_power_mode = "auto" },
      { radio = "6e", channel = tostring(ch["6e"]), ht = 160, tx_power_mode = "auto" },
    ]
  }

  # Ports with nothing cabled to them, per switch and by index.
  disabled = {
    core        = concat(range(10, 18), [23, 24, 26, 28])
    office      = concat(range(4, 8), [10])
    living_room = concat(range(6, 8), [10])
  }

  # Each device's static management address, by host name: the address it
  # holds today, which is the inventory's and its reservation on the
  # router, so the device, the lease and the inventory agree. The device
  # keeps it with the router down. The router is the gateway, and the
  # resolver is the anycast address the router's DHCP server hands out.
  static = {
    for host, ip in local.ipv4 : host => {
      type    = "static"
      ip      = ip
      netmask = cidrnetmask(var.mgmt0_gateway4)
      gateway = split("/", var.mgmt0_gateway4)[0]
      dns1    = local.dns4
    }
  }

  # Network name to controller id, for the locked ports.
  network_id = merge(
    { mgmt0 = unifi_network.mgmt0.id },
    { for name, network in unifi_network.vlan : name => network.id },
  )
}

resource "unifi_device" "switch_core" {
  name           = "switch-core"
  config_network = local.static["switch-core"]

  # A port with a profile takes every setting from it and the controller
  # discards the port's own, a MAC filter included, so a locked port
  # carries no profile and states its settings itself.
  dynamic "port_override" {
    for_each = local.locked
    content {
      index                 = tonumber(port_override.key)
      name                  = port_override.value.name
      setting_preference    = "manual"
      native_networkconf_id = local.network_id[port_override.value.network]
      tagged_vlan_mgmt      = try(port_override.value.trunk, false) ? "auto" : can(port_override.value.tagged) ? "custom" : "block_all"
      forward               = try(port_override.value.trunk, false) ? "all" : can(port_override.value.tagged) ? "customize" : "native"
      # The controller records a port's tagged networks as the ones it
      # excludes.
      excluded_networkconf_ids = can(port_override.value.tagged) ? [
        for name, id in local.network_id : id
        if name != port_override.value.network && !contains(port_override.value.tagged, name)
      ] : null
      port_security_enabled     = can(port_override.value.host)
      port_security_mac_address = can(port_override.value.host) ? concat([local.mac[port_override.value.host]], try(port_override.value.extra_macs, [])) : null
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
    index           = 18
    name            = "switch-office"
    port_profile_id = unifi_port_profile.trunk.id
  }
}

# The basement access point. Its trunk is core port 20, above.
resource "unifi_device" "ap_basement" {
  name           = "ap-basement"
  config_network = local.static["ap-basement"]
  radio_table    = local.radios.ap_basement
}

# The living room access point, on the living room switch's port 8,
# which powers it.
resource "unifi_device" "ap_living_room" {
  name           = "ap-living-room"
  config_network = local.static["ap-living-room"]
  radio_table    = local.radios.ap_living_room
}

# The laundry room access point. Its trunk is core port 21, above.
resource "unifi_device" "ap_laundry_room" {
  name           = "ap-laundry-room"
  config_network = local.static["ap-laundry-room"]
  radio_table    = local.radios.ap_laundry_room
}

# The movie room access point, on the office switch's port 8, above.
resource "unifi_device" "ap_movie_room" {
  name           = "ap-movie-room"
  config_network = local.static["ap-movie-room"]
  radio_table    = local.radios.ap_movie_room
}

# The office switch, on the run from core port 18 into its 10GBASE-T port.
# Both ends of the run are trunks, so a port here can carry any network.
# Disabled ports as on the core, above.
resource "unifi_device" "switch_office" {
  name           = "switch-office"
  config_network = local.static["switch-office"]

  port_override {
    index           = 9
    name            = "switch-core"
    port_profile_id = unifi_port_profile.trunk.id
  }

  # The movie room access point, powered by its own injector since this
  # switch has no PoE.
  port_override {
    index           = 8
    name            = "ap-movie-room"
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
  name           = "switch-living-room"
  config_network = local.static["switch-living-room"]

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
