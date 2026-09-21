variable "ssh_bootstrap_cidrs" {
  type        = map(list(string))
  default     = {}
  description = <<-EOT
    Per site, the IPv4 ranges allowed to reach SSH, for the window between
    an instance booting and Tailscale coming up on it. Empty by default:
    once a host is on the tailnet, port 22 does not need to be open to the
    internet. Keyed by site so bootstrapping a new one does not open SSH at
    a site that has been up for months.

    The gate takes a module name and nothing else, so -var cannot be passed
    through it. It runs tofu with -chdir into this directory, which means a
    terraform.tfvars here is picked up automatically:

      printf 'ssh_bootstrap_cidrs = { iad = ["203.0.113.4/32"] }\n' \
        > terraform/aws/terraform.tfvars
      sops-gate tofu-apply aws

    Deleting that file and applying again removes the rule. It is
    gitignored: it is a bootstrap window, not configuration.
  EOT
}

variable "instance_types" {
  type        = map(string)
  default     = {}
  description = <<-EOT
    Per site, an override for the t3.small default.

    nixos/deploy copies a derivation to the target and realises it there, so
    these machines build their own systems rather than receiving a closure.
    That sets the floor: t3.micro's 1 GiB is not enough. Raise a site for a
    large rebuild and lower it afterwards; the root volume persists. Keyed by
    site so raising one does not stop and start the other.
  EOT
}
