# Managed with OpenTofu (tofu, from the flake dev shell), applied from the
# workstation. The tailnet API credential is an OAuth client scoped to policy
# file writes only, provided via the TAILSCALE_OAUTH_CLIENT_ID and
# TAILSCALE_OAUTH_CLIENT_SECRET environment variables; it is never stored in
# this repository or on the development container.
terraform {
  required_version = ">= 1.8.0"

  required_providers {
    tailscale = {
      source  = "tailscale/tailscale"
      version = ">= 0.17.0"
    }
  }
}

provider "tailscale" {
  # Credentials and tailnet come from the environment; see above.
}
