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
  # Switch ports by device and index, also checked against the inventory
  # by the flake check unifi-cabling. manual ports state their own
  # settings, trunks name their far-end device, disabled ports have
  # nothing cabled.
  ports = jsondecode(file("${path.module}/ports.json"))

  # Core ports: label, the host whose MAC alone may use the port, and the
  # untagged network. trunk tags every other network, tagged lists the
  # tagged ones, and otherwise tagged frames are blocked. A new host's
  # port opens unlocked until its lease is in the inventory. extra names
  # the host's other MACs in local.extra.
  #
  # The server's ports are unlocked: they carry its containers' MACs. The
  # router's standby sends LLDP from that port's own MAC.
  locked = local.ports["switch-core"].manual

  # Office ports: label and untagged network, tagged frames blocked. No
  # host: the switch cannot lock a port to a MAC.
  office = local.ports["switch-office"].manual

  # Living room ports, as the office ones.
  living_room = local.ports["switch-living-room"].manual

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

  # The RSTP root. Every switch uplinks here, so a loop anywhere blocks
  # a port on the leaf that formed it, never a core uplink. The other
  # switches keep the default priority.
  stp_priority = 4096

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
      port_security_mac_address = can(port_override.value.host) ? concat([local.mac[port_override.value.host]], [for name in try(port_override.value.extra, []) : local.extra[name]]) : null
    }
  }

  dynamic "port_override" {
    for_each = toset(local.ports["switch-core"].disabled)
    content {
      index           = port_override.value
      name            = "unused"
      port_profile_id = unifi_port_profile.disabled.id
    }
  }

  # Uplinks to the other switches and access points.
  dynamic "port_override" {
    for_each = local.ports["switch-core"].trunks
    content {
      index           = tonumber(port_override.key)
      name            = port_override.value
      port_profile_id = unifi_port_profile.trunk.id
    }
  }
}

# The basement access point, on core port 20.
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

# The laundry room access point, on core port 21.
resource "unifi_device" "ap_laundry_room" {
  name           = "ap-laundry-room"
  config_network = local.static["ap-laundry-room"]
  radio_table    = local.radios.ap_laundry_room
}

# The movie room access point, on office switch port 8.
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

  # The uplink and the movie room access point, powered by an injector.
  dynamic "port_override" {
    for_each = local.ports["switch-office"].trunks
    content {
      index           = tonumber(port_override.key)
      name            = port_override.value
      port_profile_id = unifi_port_profile.trunk.id
    }
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
    for_each = toset(local.ports["switch-office"].disabled)
    content {
      index           = port_override.value
      name            = "unused"
      port_profile_id = unifi_port_profile.disabled.id
    }
  }
}

# The movie room switch, on the DAC from core port 26 into its SFP+ port.
# Both ends of the DAC are trunks. Disabled ports as on the core, above.
resource "unifi_device" "switch_movie_room" {
  name           = "switch-movie-room"
  config_network = local.static["switch-movie-room"]

  dynamic "port_override" {
    for_each = local.ports["switch-movie-room"].trunks
    content {
      index           = tonumber(port_override.key)
      name            = port_override.value
      port_profile_id = unifi_port_profile.trunk.id
    }
  }

  dynamic "port_override" {
    for_each = toset(local.ports["switch-movie-room"].disabled)
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

  # The uplink and the living room access point.
  dynamic "port_override" {
    for_each = local.ports["switch-living-room"].trunks
    content {
      index           = tonumber(port_override.key)
      name            = port_override.value
      port_profile_id = unifi_port_profile.trunk.id
    }
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
    for_each = toset(local.ports["switch-living-room"].disabled)
    content {
      index           = port_override.value
      name            = "unused"
      port_profile_id = unifi_port_profile.disabled.id
    }
  }
}
