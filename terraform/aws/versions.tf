# Managed with OpenTofu, applied from the development container through the
# secrets gate (`sops-gate tofu-apply aws`; see nixos/servnerr-4/dev.nix).
# Credentials live in secrets/aws.yaml, encrypted to the admin and the gate,
# whose top-level keys are the AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY
# environment variables the provider reads.
#
# What this builds is the far end of a site interconnect: one dual-stack host
# which terminates a WireGuard carrier from azo and routes for our AS. It
# provisions the machine and the path to it, nothing on it. The NixOS
# configuration lives in nixos/pdx/ and arrives by nixos/deploy.
terraform {
  required_version = ">= 1.8.0"

  # State is local to the gate, as with the other modules here: the path is
  # supplied at init time (-backend-config), so this directory is only ever
  # read. Nothing in the state is secret: the endpoint address it holds also
  # appears in the NixOS configuration at the other end of the circuit.
  backend "local" {}

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0.0"
    }
  }
}

provider "aws" {
  region = local.region

  # Credentials come from the environment; see above.

  default_tags {
    tags = {
      ManagedBy = "opentofu"
      Repo      = "homelab"
      Site      = local.site
    }
  }
}
