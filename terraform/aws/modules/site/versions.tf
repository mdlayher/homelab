# The provider is configured by the root and passed in, so the region lives
# with the site's other settings rather than here.
terraform {
  required_version = ">= 1.8.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0.0"
    }
  }
}
