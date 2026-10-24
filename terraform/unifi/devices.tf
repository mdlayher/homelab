# The switches and access points. The controller adopts a device in the
# UI; it then enters the state through an import by its MAC
# (sops-gate tofu-import unifi unifi_device.<name> <mac>), so no MAC is
# written here. A port a device lists takes the named profile; every
# other port keeps the controller's default, the built-in All profile,
# which carries every network with mgmt0 untagged.

# The rack's core switch. Devices in the rack fill the copper ports from
# port 1 up; runs to the rest of the house and the uplinks to other
# switches fill them from port 22 down, so the two groups meet in the
# free middle. The SFP+ cages hold the router and the server.
locals {
  # Ports locked to one host each, by port index: the port's label, the
  # host whose hardware address alone may use it, and the network the
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

  # The living room switch's uplink.
  port_override {
    index           = 19
    name            = "switch-livingroom"
    port_profile_id = unifi_port_profile.trunk.id
  }

  port_override {
    index           = 20
    name            = "ap-basement"
    port_profile_id = unifi_port_profile.trunk.id
  }

  port_override {
    index           = 21
    name            = "ap-laundry"
    port_profile_id = unifi_port_profile.trunk.id
  }

  # The run to the office, with the workstation on its far end.
  port_override {
    index           = 22
    name            = "office run"
    port_profile_id = unifi_port_profile.mgmt0.id
  }

  # The server's 10G port; see the server profile.
  port_override {
    index           = 27
    name            = "server 10g"
    port_profile_id = unifi_port_profile.server.id
  }
}
