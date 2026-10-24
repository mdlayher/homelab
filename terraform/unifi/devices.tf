# The switches and access points. The controller adopts a device in the
# UI; it then enters the state through an import by its MAC
# (sops-gate tofu-import unifi unifi_device.<name> <mac>), so no MAC is
# written here. A port a device lists takes the named profile; every
# other port keeps the controller's default, the built-in All profile,
# which carries every network with mgmt0 untagged.

# The rack's core switch.
resource "unifi_device" "switch_core" {
  name = "switch-core"

  # The router's trunk: mgmt0 untagged with every VLAN tagged, as the
  # router's networking.nix expects on its LAN port.
  port_override {
    index           = 25
    name            = "router"
    port_profile_id = unifi_port_profile.trunk.id
  }

  # Uplink to the Aruba 1930, the other rack switch.
  port_override {
    index           = 28
    name            = "aruba 1930"
    port_profile_id = unifi_port_profile.trunk.id
  }
}
