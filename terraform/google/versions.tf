# Managed with OpenTofu, applied from the development container through the
# secrets gate (`sops-gate tofu-apply google`; see nixos/servnerr-4/dev.nix).
# The credential is a service account key for the homelab Google Cloud
# project with the Pub/Sub Admin role. It lives in secrets/google.yaml,
# encrypted to the admin and the gate, whose top-level key is the
# GOOGLE_CREDENTIALS environment variable the provider reads (the key file's
# JSON as a string).
terraform {
  required_version = ">= 1.8.0"

  # State is local to the gate: the path is supplied at init time
  # (-backend-config) and points into the gate user's state directory, so
  # this module directory is only ever read. Nothing in the state is
  # secret; the resources are the files beside this one.
  backend "local" {}

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 6.0.0"
    }
  }
}

provider "google" {
  # Credentials come from the environment; see above. The project ID is
  # public (it is the Pub/Sub resource path Home Assistant logs).
  project = "homelab-277601"
}
