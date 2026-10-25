locals {
  # The admin's SSH public key, as the machines read it (nixos/ssh-keys.nix):
  # type, key and comment.
  admin_key = split(" ", chomp(file("${path.module}/../../nixos/ssh-keys/admin.pub")))
}

resource "unifi_setting" "site" {
  # The regulatory domain, as an ISO 3166-1 numeric code: the United States.
  country = {
    code = 840
  }

  # Every access point is wired, so no radio is held back for a mesh
  # backhaul and each band carries the controller's full SSID count. The
  # controller fills in the rest of the block, so it is written out here
  # as the controller holds it.
  connectivity = {
    enabled          = false
    mlo_mesh_enabled = false
    uplink_type      = "gateway"
  }

  # Device firmware upgrades itself at the hour the NixOS machines run
  # their nightly upgrade. SSH onto a device takes the admin's key alone.
  mgmt = {
    auto_upgrade              = true
    auto_upgrade_hour         = 4
    ssh_enabled               = true
    ssh_auth_password_enabled = false
    ssh_keys = [{
      name    = "admin"
      type    = local.admin_key[0]
      key     = local.admin_key[1]
      comment = join(" ", slice(local.admin_key, 2, length(local.admin_key)))
    }]
  }

  # Switches run RSTP toward one another and report any DHCP server they
  # see. Every segment carries the standard MTU, so no jumbo frames. No
  # 802.1X and no switch ACLs: the router keeps the segments apart.
  global_switch = {
    stp_version            = "rstp"
    dhcp_snoop             = true
    jumboframe_enabled     = false
    dot1x_portctrl_enabled = false
    acl_device_isolation   = []
  }

  # Time from the anycast NTP address (nixos/inventory/default.nix,
  # anycast4), the server DHCP hands every LAN client. The provider leaves
  # an empty server slot out of its write, so a slot the controller already
  # holds is cleared in the UI, never from here.
  ntp = {
    setting_preference = "manual"
    ntp_server_1       = "10.0.0.123"
  }

  # Device logs to the raw syslog listener of the machine holding the loki
  # service (nixos/inventory/default.nix, services), which labels each
  # sender by its inventory address (nixos/servnerr-4/loki.nix). The
  # controller's own log reaches Loki from its journal already.
  syslog = {
    enabled          = true
    ip               = "loki.svc.mdlayher.net"
    port             = 5514
    log_all_contents = true
    this_controller  = false
  }
}
