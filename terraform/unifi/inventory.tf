# The inventory's hardware addresses, from nixos/inventory/secrets.yaml,
# which the gate's key decrypts (sops-gate exports SOPS_AGE_KEY_FILE). A
# port locked to one host names the host here and the address stays in
# the inventory, where every other consumer of it reads it.
data "sops_file" "inventory" {
  source_file = "${path.module}/../../nixos/inventory/secrets.yaml"
}

locals {
  # Host name to MAC, from the inventory's hosts. The data source marks
  # what it reads sensitive, and a plan hides every port block of a device
  # once one carries a sensitive address, -show-sensitive notwithstanding.
  # A plan prints on the admin's own terminal, so the addresses are
  # unmarked here.
  mac = merge(
    nonsensitive({
      for key, value in data.sops_file.inventory.data :
      regex("^hosts\\.([^.]+)\\.mac$", key)[0] => value
      if can(regex("^hosts\\.[^.]+\\.mac$", key))
    }),
    # The router is no inventory host. Its management LAN bond carries the
    # address its networking.nix gives it (netdevs."15-mgmt0") on whichever
    # port is active, and every VLAN on the bond shares it.
    { routnerr-3 = "f4:90:ea:00:c7:90" },
  )

  # Addresses the inventory does not record, named for the host and the
  # interface sending from them. systemd derives the dn42 addresses, so
  # they hold across reboots.
  extra = {
    "routnerr-3 1g"   = "f4:90:ea:00:c7:8e"
    "servnerr-4 10g"  = "8c:dc:d4:ac:96:24"
    "servnerr-4 dn42" = "f6:e6:4f:4d:d9:ed"
    "linuxdev dn42"   = "ea:97:cc:a4:ae:c3"
  }

  # Host name to IPv4 address, from the inventory's hosts, unmarked as the
  # MACs are above.
  ipv4 = nonsensitive({
    for key, value in data.sops_file.inventory.data :
    regex("^hosts\\.([^.]+)\\.ipv4$", key)[0] => value
    if can(regex("^hosts\\.[^.]+\\.ipv4$", key))
  })

  # The anycast resolver's IPv4 address, read from the inventory's plain
  # data (anycast4.dns) so it is written in one place.
  dns4 = regex("anycast4 = \\{[^}]*dns = \"([0-9.]+)\";", file("${path.module}/../../nixos/inventory/default.nix"))[0]
}
