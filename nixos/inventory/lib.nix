# Helpers for computing IPv6 interface identifiers by hand, for example:
#
#   nix eval --raw --impure --expr \
#     '(import ./nixos/inventory/lib.nix { lib = (builtins.getFlake (toString ./.)).inputs.nixpkgs.lib; }).eui64 "02:00:5e:00:53:01"'
#
# The result is the "iid" value stored for a host in secrets.yaml: exactly four
# hex groups, joined to a subnet prefix as "<prefix>:<iid>".
{ lib }:

let
  inherit (builtins) bitXor elemAt;

  # Parses a MAC address string into 6 integer bytes.
  parseMAC = s: map lib.fromHexString (lib.splitString ":" s);

  # Formats four 16-bit groups as lowercase hex without leading zeros.
  formatIID = lib.concatMapStringsSep ":" (g: lib.toLower (lib.toHexString g));
in
{
  # Computes the modified EUI-64 interface identifier for a MAC address.
  eui64 =
    mac:
    let
      m = parseMAC mac;
      b = i: elemAt m i;
      # Flip the universal/local bit of the first octet.
      b0 = bitXor (b 0) 2;
    in
    formatIID [
      (b0 * 256 + b 1)
      (b 2 * 256 + 255)
      (254 * 256 + b 3)
      (b 4 * 256 + b 5)
    ];

  # Formats a small integer as a static token interface identifier, e.g.
  # token 10 -> "0:0:0:a", matching networkd Token=static:::a.
  token =
    n:
    formatIID [
      0
      0
      0
      n
    ];
}
