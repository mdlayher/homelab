# The tailnet policy file, kept in policy.hujson so the HuJSON comments
# survive review. Before the first apply, reconcile policy.hujson against the
# live policy (admin console, Access controls) and adopt the existing state:
#
#   tofu init
#   tofu import tailscale_acl.tailnet acl
#   tofu plan
#
# The first plan must show only the intended hardening delta, nothing else.
resource "tailscale_acl" "tailnet" {
  acl = file("${path.module}/policy.hujson")
}
