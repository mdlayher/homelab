# Applied through the secrets gate (`sops-gate tofu-apply healthchecks`; see
# nixos/servnerr-4/dev.nix) with a read-write project API key from
# secrets/healthchecks.yaml, keyed HEALTHCHECKSIO_API_KEY.
terraform {
  required_version = ">= 1.8.0"

  # State lives in the gate's state directory (-backend-config at init). It
  # holds the check's ping URL, a secret.
  backend "local" {}

  required_providers {
    healthchecksio = {
      source  = "kristofferahl/healthchecksio"
      version = "2.3.0"
    }
  }
}

provider "healthchecksio" {}
