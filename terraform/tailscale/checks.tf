# What the tailnet must look like, asserted against the control plane on
# every plan. A failed assertion is a warning in the plan output rather
# than an error, so an unexpected machine, tag, user, client or lock state
# surfaces beside whatever change is being planned.
data "tailscale_devices" "all" {}

data "tailscale_users" "all" {}

locals {
  # The one human; personal devices are the untagged ones and belong to
  # this login. The policy names the same login in its admin group.
  admin = "mdlayher@gmail.com"

  # Every tagged machine's tags, by hostname. A machine absent from the
  # tailnet is not a finding (it may be mid-reinstall); one present with
  # other tags, or one not listed here, is.
  machine_tags = {
    linuxdev    = ["tag:dev"]
    servnerr-4  = ["tag:infra"]
    routnerr-3  = ["tag:infra", "tag:router"]
    edge-iad    = ["tag:edge"]
    edge-pdx    = ["tag:edge"]
    hass        = ["tag:hass"]
    pikvm       = ["tag:kvm"]
    jumpnerr-1  = ["tag:oob"]
    gamnerr-1   = ["tag:windows"]
    theatnerr-2 = ["tag:windows"]
  }

  # The oldest client release allowed on any device, as its minor version,
  # read from the policy's posture so the floor is set in one place.
  min_client_minor = tonumber(regex("node:tsVersion >= '1\\.(\\d+)'", file("${path.module}/policy.hujson"))[0])

  devices  = data.tailscale_devices.all.devices
  tagged   = [for d in local.devices : d if length(d.tags) > 0]
  untagged = [for d in local.devices : d if length(d.tags) == 0]

  # Machines whose tags are not the expected set, or which are not listed.
  mistagged = [
    for d in local.tagged : d.hostname
    if toset(d.tags) != toset(lookup(local.machine_tags, d.hostname, []))
  ]
  foreign_personal = [for d in local.untagged : d.hostname if d.user != local.admin]
  lock_errors      = [for d in local.devices : d.hostname if d.tailnet_lock_error != null && d.tailnet_lock_error != ""]
  unlocked         = [for d in local.devices : d.hostname if d.tailnet_lock_key == null || d.tailnet_lock_key == ""]
  expiring         = [for d in local.tagged : d.hostname if !d.key_expiry_disabled]
  unauthorized     = [for d in local.devices : d.hostname if !d.authorized || d.is_external]
  old_clients = [
    for d in local.devices : "${d.hostname} ${d.client_version}"
    if !try(tonumber(regex("^1\\.(\\d+)", d.client_version)[0]) >= local.min_client_minor, false)
  ]
}

check "users" {
  assert {
    condition     = [for u in data.tailscale_users.all.users : u.login_name] == [local.admin]
    error_message = "tailnet users are ${join(", ", [for u in data.tailscale_users.all.users : u.login_name])}; expected only ${local.admin}"
  }
}

check "machine_tags" {
  assert {
    condition     = length(local.mistagged) == 0
    error_message = "machines with unexpected tags: ${join(", ", local.mistagged)}"
  }
}

check "personal_devices" {
  assert {
    condition     = length(local.foreign_personal) == 0
    error_message = "untagged devices not owned by ${local.admin}: ${join(", ", local.foreign_personal)}"
  }
}

# Every node generates a tailnet lock key whether or not the lock is on,
# so a device without one is a node the lock cannot cover, such as a
# client from before tailnet lock existed.
check "tailnet_lock" {
  assert {
    condition     = length(local.lock_errors) == 0
    error_message = "devices with a tailnet lock error: ${join(", ", local.lock_errors)}"
  }
  assert {
    condition     = length(local.unlocked) == 0
    error_message = "devices without a tailnet lock key: ${join(", ", local.unlocked)}"
  }
}

check "key_expiry" {
  assert {
    condition     = length(local.expiring) == 0
    error_message = "tagged machines with key expiry enabled: ${join(", ", local.expiring)}"
  }
}

check "authorized" {
  assert {
    condition     = length(local.unauthorized) == 0
    error_message = "devices unauthorized or external: ${join(", ", local.unauthorized)}"
  }
}

check "client_version" {
  assert {
    condition     = length(local.old_clients) == 0
    error_message = "clients older than 1.${local.min_client_minor}: ${join(", ", local.old_clients)}"
  }
}
