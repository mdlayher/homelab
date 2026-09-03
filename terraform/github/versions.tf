# Managed with OpenTofu, applied from the development container through the
# secrets gate (`sops-gate tofu-apply github`; see nixos/servnerr-4/dev.nix).
# The credential is a fine-grained PAT with Administration read/write on the
# repositories below. It lives in secrets/github.yaml, encrypted to the admin
# and the gate, whose top-level key is the GITHUB_TOKEN environment variable
# the provider reads.
terraform {
  required_version = ">= 1.8.0"

  # State is local to the gate: the path is supplied at init time
  # (-backend-config) and points into the gate user's state directory, so
  # this module directory is only ever read. Nothing in the state is
  # secret; the rules are the file beside this one.
  backend "local" {}

  required_providers {
    github = {
      source  = "integrations/github"
      version = ">= 6.0.0"
    }
  }
}

provider "github" {
  owner = "mdlayher"
}
