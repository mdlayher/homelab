# The UniFi switching and Wi-Fi configuration, managed with OpenTofu and
# applied from the development container through the secrets gate
# (`sops-gate tofu-apply unifi`; see nixos/servnerr-4/dev.nix). The
# controller is the UniFi Network application on the server (see
# nixos/servnerr-4/unifi.nix). The controller moves to another host by
# restoring one of its backups there, after which only UNIFI_API changes.
#
# Credentials live in secrets/unifi.yaml, encrypted to the admin and the
# gate, whose top-level keys are the environment variables the provider and
# variables.tf read: UNIFI_API, UNIFI_USERNAME and UNIFI_PASSWORD, and
# TF_VAR_mgmt0_gateway4. The self-hosted application accepts no API key, so
# the provider logs in as the local admin.
#
# The controller is the running truth. A plan shows drift only in the
# attributes written here; everything else on an object is the
# controller's to choose. Adoption is done by hand in the UI.
terraform {
  required_version = ">= 1.8.0"

  # State is local to the gate: the path is supplied at init time
  # (-backend-config) and points into the gate user's state directory, so
  # this module directory is only ever read.
  backend "local" {}

  required_providers {
    unifi = {
      source  = "ubiquiti-community/unifi"
      version = ">= 0.59.0"
    }
    time = {
      source  = "hashicorp/time"
      version = ">= 0.13.0"
    }
  }
}

provider "unifi" {
  # Credentials and the controller's URL come from the environment; see
  # above. The controller serves a self-signed certificate.
  allow_insecure = true
}
