# The inventory's hardware addresses, from nixos/inventory/secrets.yaml,
# which the gate's key decrypts (sops-gate exports SOPS_AGE_KEY_FILE). A
# port locked to one host names the host here and the address stays in
# the inventory, where every other consumer of it reads it.
data "sops_file" "inventory" {
  source_file = "${path.module}/../../nixos/inventory/secrets.yaml"
}

locals {
  # Host name to MAC, from the inventory's hosts.
  mac = {
    for key, value in data.sops_file.inventory.data :
    regex("^hosts\\.([^.]+)\\.mac$", key)[0] => value
    if can(regex("^hosts\\.[^.]+\\.mac$", key))
  }
}
