# The CyberPower cards, read by cyberpower/default.nix for the desired
# state it builds and by cyberpower/deploy for what it applies to: the
# PDUs, the inventory hosts tagged pdu, and the UPSes, those tagged ups.
rec {
  pdus = import ../nixos/inventory/tagged.nix "pdu";
  upses = import ../nixos/inventory/tagged.nix "ups";
  hosts = pdus ++ upses;
}
