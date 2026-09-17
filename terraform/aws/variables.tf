variable "ssh_bootstrap_cidrs" {
  type        = list(string)
  default     = []
  description = <<-EOT
    IPv4 ranges allowed to reach SSH, for the window between the instance
    booting and Tailscale coming up on it. Empty by default: once the host
    is on the tailnet, port 22 does not need to be open to the internet.

    The gate takes a module name and nothing else, so -var cannot be passed
    through it. It runs tofu with -chdir into this directory, which means a
    terraform.tfvars here is picked up automatically:

      printf 'ssh_bootstrap_cidrs = ["203.0.113.4/32"]\n' \
        > terraform/aws/terraform.tfvars
      sops-gate tofu-apply aws

    Deleting that file and applying again removes the rule. It is
    gitignored: it is a bootstrap window, not configuration.
  EOT
}

variable "instance_type" {
  type        = string
  default     = "t3.small"
  description = <<-EOT
    nixos/deploy copies a derivation to the target and realises it there, so
    this machine builds its own system rather than receiving a closure. That
    sets the floor: t3.micro's 1 GiB is not enough. Raise this for a large
    rebuild and lower it afterwards; the root volume persists.
  EOT
}
