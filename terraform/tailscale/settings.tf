# Tailnet-wide settings. Device approval is off because tailnet lock is the
# gate on new nodes: the two cannot be enabled together, and approval is
# granted by the same account whose compromise it would need to stop. The
# lock itself is not a setting: it is enabled once from a signing node.
resource "tailscale_tailnet_settings" "tailnet" {
  devices_approval_on = false
  # New users need an admin's approval, and only admins may join another
  # tailnet from this one.
  users_approval_on                           = true
  users_role_allowed_to_join_external_tailnet = "admin"
  # Key expiry applies to personal devices; tagged machines never expire.
  devices_key_duration_days      = 180
  devices_auto_updates_on        = true
  posture_identity_collection_on = true
  https_enabled                  = true
  regional_routing_on            = false
  # The policy file is written from this module alone; the console refuses
  # edits and points at the file.
  acls_externally_managed_on = true
  acls_external_link         = "https://github.com/mdlayher/homelab/blob/main/terraform/tailscale/policy.hujson"
}
