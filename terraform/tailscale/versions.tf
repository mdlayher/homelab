# Managed with OpenTofu, applied from the development container through the
# secrets gate (`sops-gate tofu-apply tailscale`; see
# nixos/servnerr-4/dev.nix). The tailnet API credential is an OAuth client
# scoped to policy file and services writes only, and owning tag:infra so it
# may tag the services it creates. It lives in secrets/tailscale.yaml,
# encrypted to the admin and the gate, whose top-level keys are the
# TAILSCALE_OAUTH_CLIENT_ID and TAILSCALE_OAUTH_CLIENT_SECRET environment
# variables the provider reads.
terraform {
  required_version = ">= 1.8.0"

  # State is local to the gate: the path is supplied at init time
  # (-backend-config) and points into the gate user's state directory, so
  # this module directory is only ever read. Nothing in the state is
  # secret; the policy and services are the files beside this one.
  backend "local" {}

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
