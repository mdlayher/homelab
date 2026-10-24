# The switches and access points. The controller adopts a device in the
# UI; it then enters the state through an import by its MAC
# (sops-gate tofu-import unifi unifi_device.<name> <mac>), so no MAC is
# written here. A port a device lists takes the named profile; every
# other port keeps the controller's default, the built-in All profile,
# which carries every network with mgmt0 untagged.

# The rack's core switch. Devices in the rack fill the copper ports from
# port 1 up; runs to the rest of the house and the uplinks to other
# switches fill them from port 22 down, so the two groups meet in the
# free middle. The SFP+ cages hold the router, the server and the Aruba.
locals {
  # Management LAN ports locked to one host each, by port index: the
  # port's label and the inventory host whose hardware address alone may
  # use it.
  locked = {
    1 = { name = "kvm", host = "pikvm" }
    3 = { name = "jump", host = "jumpnerr-1" }
  }
}

resource "unifi_device" "switch_core" {
  name = "switch-core"

  # A port with a profile takes every setting from it and the controller
  # discards the port's own, a MAC filter included, so a locked port
  # carries no profile and states the mgmt0 profile's settings itself:
  # mgmt0 untagged, tagged frames blocked.
  dynamic "port_override" {
    for_each = local.locked
    content {
      index                     = tonumber(port_override.key)
      name                      = port_override.value.name
      setting_preference        = "manual"
      native_networkconf_id     = unifi_network.mgmt0.id
      tagged_vlan_mgmt          = "block_all"
      forward                   = "native"
      port_security_enabled     = true
      port_security_mac_address = [local.mac[port_override.value.host]]
    }
  }

  port_override {
    index           = 2
    name            = "server 1g"
    port_profile_id = unifi_port_profile.mgmt0.id
  }

  port_override {
    index           = 4
    name            = "hass"
    port_profile_id = unifi_port_profile.mgmt0.id
  }

  port_override {
    index           = 5
    name            = "pdu01"
    port_profile_id = unifi_port_profile.mgmt0.id
  }

  port_override {
    index           = 6
    name            = "ups01"
    port_profile_id = unifi_port_profile.mgmt0.id
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

  # The router's trunk: mgmt0 untagged with every VLAN tagged, as the
  # router's networking.nix expects on its LAN port.
  port_override {
    index           = 25
    name            = "router"
    port_profile_id = unifi_port_profile.trunk.id
  }

  # The server's 10G port; see the server profile.
  port_override {
    index           = 27
    name            = "server 10g"
    port_profile_id = unifi_port_profile.server.id
  }

  # Uplink to the Aruba 1930, the other rack switch.
  port_override {
    index           = 28
    name            = "aruba 1930"
    port_profile_id = unifi_port_profile.trunk.id
  }
}
