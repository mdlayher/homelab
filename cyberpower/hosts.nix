# The CyberPower PDUs, the inventory hosts tagged pdu, read by
# cyberpower/default.nix for the desired state it builds and by
# cyberpower/deploy for what it applies to.
{
  hosts = import ../nixos/inventory/tagged.nix "pdu";
}
