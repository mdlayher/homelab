# Tailnet-wide settings, as the console held them when they were adopted.
# Device approval is the gate on new nodes until tailnet lock takes that
# role; the two cannot be enabled together. The lock itself is not a
# setting: it is enabled once from a signing node (see nixos/README.md).
resource "tailscale_tailnet_settings" "tailnet" {
  devices_approval_on = true
  # New users need an admin's approval, and only admins may join another
  # tailnet from this one.
  users_approval_on                           = true
  users_role_allowed_to_join_external_tailnet = "admin"
  # Key expiry applies to personal devices; tagged machines never expire.
  devices_key_duration_days      = 180
  devices_auto_updates_on        = false
  posture_identity_collection_on = true
  https_enabled                  = true
  regional_routing_on            = false
  # The policy file is applied from this module, but the console may still
  # edit it.
  acls_externally_managed_on = false
}
