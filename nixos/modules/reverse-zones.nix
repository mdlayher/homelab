# Expanding an IPv6 address into the nibbles an ip6.arpa name is built from.
# Plain functions rather than a module: the resolver needs this for the site
# ULA and dn42 needs it for the zones the registry delegates, and one copy
# keeps the two from drifting.
{ lib }:

{
  # The 32 nibbles of an IPv6 address, most significant first, with "::"
  # expanded.
  nibbles6 =
    addr:
    let
      sides = lib.splitString "::" addr;
      groups = side: if side == "" then [ ] else lib.splitString ":" side;
      before = groups (lib.head sides);
      after = if lib.length sides > 1 then groups (lib.last sides) else [ ];
      gap = lib.replicate (8 - lib.length before - lib.length after) "0";
    in
    lib.concatMap (group: lib.stringToCharacters (lib.fixedWidthString 4 "0" group)) (
      before ++ gap ++ after
    );
}
