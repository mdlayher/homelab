# Managed with OpenTofu, applied from the development container through the
# secrets gate (`sops-gate tofu-apply aws`; see nixos/servnerr-4/dev.nix).
# Credentials live in secrets/aws.yaml, encrypted to the admin and the gate,
# whose top-level keys are the AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY
# environment variables the provider reads.
#
# What this builds is the far end of a site interconnect: per site, one
# dual-stack host which terminates WireGuard carriers and routes for our AS.
# It provisions the machines and the paths to them, nothing on them. The
# NixOS configurations live in nixos/edge-<site>/ and arrive by nixos/deploy.
terraform {
  required_version = ">= 1.8.0"

  # State is local to the gate, as with the other modules here: the path is
  # supplied at init time (-backend-config), so this directory is only ever
  # read. Nothing in the state is secret: the endpoint addresses it holds
  # also appear in the NixOS configuration at the other end of each circuit.
  backend "local" {}

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0.0"
    }
  }
}

# One provider per region, since a site is pinned to one. The default is
# us-west-2 so that pdx, which was here first, keeps the provider it was
# created under and moves region for no reason.
provider "aws" {
  region = "us-west-2"

  # Credentials come from the environment; see above.

  default_tags {
    tags = {
      ManagedBy = "opentofu"
      Repo      = "homelab"
      Site      = "pdx"
    }
  }
}

provider "aws" {
  alias  = "iad"
  region = "us-east-1"

  default_tags {
    tags = {
      ManagedBy = "opentofu"
      Repo      = "homelab"
      Site      = "iad"
    }
  }
}
