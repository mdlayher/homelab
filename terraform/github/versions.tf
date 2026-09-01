# Managed with OpenTofu (tofu, from the flake dev shell), applied from the
# workstation. The credential is a fine-grained PAT with Administration
# read/write on the repositories below, provided via the GITHUB_TOKEN
# environment variable; it is never stored in this repository or on the
# development container.
terraform {
  required_version = ">= 1.8.0"

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
