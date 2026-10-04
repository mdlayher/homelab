# Evaluation-time checks on the plain data in nixos/inventory/default.nix.
# Every machine imports the inventory, so every deploy and nightly upgrade
# runs them. Addresses and MACs are sops placeholders at evaluation time and
# cannot be checked here.
{ inventory, lib, ... }:

let
  inherit (inventory) sites;

  isUnique = xs: lib.unique xs == xs;

  # Each site's subnets and their hosts, flattened across sites.
  subnets = lib.concatMap (s: lib.attrValues (s.subnets or { })) (lib.attrValues sites);
  hosts = lib.concatMap (subnet: lib.mapAttrsToList lib.nameValuePair (subnet.hosts or { })) subnets;
  hostNames = map (h: h.name) hosts;

  # Every site loopback, tagged with its machine and site.
  siteLoopbacks = lib.concatLists (
    lib.mapAttrsToList (
      site: s: lib.mapAttrsToList (machine: lo: lo // { inherit machine site; }) (s.loopbacks or { })
    ) sites
  );

  # Every machine the inventory names: a host on a segment, a loopback
  # holder, or a tailnet host.
  machines = lib.unique (
    hostNames ++ map (lo: lo.machine) siteLoopbacks ++ lib.attrNames inventory.tailnetHosts
  );
  unknown = names: lib.subtractLists machines names;

  roleHolders = lib.concatLists (lib.attrValues inventory.roles);

  # The SSRR tail of a system ID, as site and router numbers.
  systemIds = inventory.isis.systemIds;
  ssrr = id: lib.last (lib.splitString "." id);
  idSite = id: lib.toIntBase10 (lib.substring 0 2 (ssrr id));
  idRouter = id: lib.toIntBase10 (lib.substring 2 2 (ssrr id));
  # The tail as an address writes it, compressed: 0101 becomes 101.
  idTail6 = id: toString (lib.toIntBase10 (ssrr id));
  # A machine whose system ID the SSRR checks can read; a malformed one
  # fails the format check instead.
  validId = m: systemIds ? ${m} && builtins.match "0000\\.0000\\.[0-9]{4}" systemIds.${m} != null;

  # The /48 without its length, and the fourth hextet of a /56 cut from it.
  ulaBase = lib.removeSuffix "::/48" inventory.ulaPrefix6;
  carveOuts = [
    inventory.labPrefix6
    inventory.carrierPrefix6
    inventory.locatorPrefix6
    inventory.circuitPrefix6
    inventory.remotePrefix6
  ];
  carveOutHextet = p: lib.removeSuffix "00::/56" (lib.removePrefix "${ulaBase}:" p);
  # The checks reading a hextet skip a malformed carve-out, which fails the
  # form check instead.
  carveOutValid = p: builtins.match "${ulaBase}:[0-9a-f]{2}00::/56" p != null;
  # A site's highest subnet hextet, decimal SSVV read as the hex it is
  # written in.
  siteTopHextet = s: lib.fromHexString (toString (100 * s.index + 99));

  # IPv4 prefixes as integer ranges, to test containment and overlap.
  ip4ToInt = a: lib.foldl' (acc: o: acc * 256 + lib.toIntBase10 o) 0 (lib.splitString "." a);
  range4 =
    cidr:
    let
      parts = lib.splitString "/" cidr;
      size = lib.foldl' (n: _: n * 2) 1 (lib.range 1 (32 - lib.toIntBase10 (lib.elemAt parts 1)));
      base = ip4ToInt (lib.head parts);
    in
    {
      first = base;
      last = base + size - 1;
      aligned = lib.mod base size == 0;
    };
  contains4 =
    outer: inner:
    (range4 outer).first <= (range4 inner).first && (range4 inner).last <= (range4 outer).last;
  overlaps4 = a: b: (range4 a).first <= (range4 b).last && (range4 b).first <= (range4 a).last;

  # The IPv4 blocks that must not meet: each site's /16 and the
  # infrastructure blocks. The anycast /24 is inside site 00's loopback
  # block by design and is checked separately.
  blocks4 = lib.mapAttrsToList (_: s: "10.${toString s.index}.0.0/16") sites ++ [
    inventory.loopbackPrefix4
    inventory.circuitPrefix4
    inventory.labPrefix4
    inventory.cloudPrefix4
  ];
  blockPairs4 = lib.concatLists (
    lib.imap0 (
      i: a:
      map (b: [
        a
        b
      ]) (lib.drop (i + 1) blocks4)
    ) blocks4
  );
in
{
  assertions = [
    # Registries.
    {
      assertion = isUnique (lib.mapAttrsToList (_: s: s.index) sites);
      message = "inventory site indices must be unique";
    }
    {
      # Site 00 is the network itself, and the circuit /31s write each
      # index as one decimal digit.
      assertion = lib.all (s: s.index >= 1 && s.index < 10) (lib.attrValues sites);
      message = "inventory site indices must be between 1 and 9";
    }
    {
      # secrets.yaml keys hosts by bare name in one file for every site.
      assertion = isUnique hostNames;
      message = "inventory host names must be unique across all sites";
    }
    {
      assertion = lib.all (s: isUnique (lib.mapAttrsToList (_: subnet: subnet.vlan) (s.subnets or { }))) (
        lib.attrValues sites
      );
      message = "inventory VLAN ids must be unique within a site";
    }
    {
      assertion = isUnique (lib.attrValues systemIds ++ lib.attrValues inventory.isis.lab.systemIds);
      message = "inventory IS-IS system IDs must be unique, the lab's included";
    }
    {
      assertion = lib.all (id: builtins.match "0000\\.0000\\.[0-9]{4}" id != null) (
        lib.attrValues systemIds
      );
      message = "inventory IS-IS system IDs must be 0000.0000.SSRR in decimal digits";
    }

    # The SSRR numbering, written once per registry.
    {
      assertion = lib.all (lo: systemIds ? ${lo.machine}) siteLoopbacks;
      message = "every inventory site loopback needs an IS-IS system ID for its machine";
    }
    {
      assertion = lib.all (
        lo: !(validId lo.machine) || idSite systemIds.${lo.machine} == sites.${lo.site}.index
      ) siteLoopbacks;
      message = "an inventory IS-IS system ID's site digits must match the index of the site holding its loopback";
    }
    {
      assertion = lib.all (
        lo:
        !(validId lo.machine)
        || (
          let
            id = systemIds.${lo.machine};
          in
          lib.hasSuffix "::${idTail6 id}" lo.addr6
          && lo.addr4 == "10.0.${toString (idSite id)}.${toString (idRouter id)}"
        )
      ) siteLoopbacks;
      message = "inventory site loopbacks must be ::SSRR and 10.0.SS.RR, from their machine's IS-IS system ID";
    }
    {
      assertion = lib.all (machine: systemIds ? ${machine}) (lib.attrNames inventory.dn42.loopbacks);
      message = "every inventory dn42 loopback needs an IS-IS system ID for its machine";
    }
    {
      assertion = lib.all (
        machine:
        let
          lo = inventory.dn42.loopbacks.${machine};
        in
        !(validId machine)
        || (
          lib.hasSuffix "::${idTail6 systemIds.${machine}}" lo.addr6
          && lib.hasPrefix "${lib.removeSuffix "::/48" inventory.dn42.net6}:" lo.addr6
          && contains4 inventory.dn42.net4 "${lo.addr4}/32"
        )
      ) (lib.attrNames inventory.dn42.loopbacks);
      message = "inventory dn42 loopbacks must come from dn42.net6 and dn42.net4, the IPv6 ending ::SSRR from the machine's IS-IS system ID";
    }

    # References.
    {
      assertion = lib.all (
        h:
        lib.elem (h.value.ipv6 or null) [
          null
          "eui64"
          "token"
          "prefixstable"
        ]
      ) hosts;
      message = "inventory host ipv6 must be eui64, token, prefixstable, or null";
    }
    {
      assertion = unknown roleHolders == [ ];
      message = "inventory roles name unknown machines: ${toString (unknown roleHolders)}";
    }
    {
      assertion = isUnique roleHolders;
      message = "an inventory machine may hold only one role";
    }
    {
      assertion = lib.all (role: inventory.roles ? ${role}) (lib.attrValues inventory.services);
      message = "every inventory service must name a role";
    }
    {
      assertion = lib.all (f: lib.elem f.host hostNames) inventory.tailscaleForwards;
      message = "every inventory tailscaleForwards host must be a host on a segment";
    }
    {
      assertion = isUnique (map (f: f.port) inventory.tailscaleForwards);
      message = "inventory tailscaleForwards ports must be unique";
    }
    {
      assertion = unknown (lib.attrNames systemIds) == [ ];
      message = "inventory IS-IS system IDs name unknown machines: ${toString (unknown (lib.attrNames systemIds))}";
    }
    {
      assertion = lib.all (
        site:
        let
          ends = inventory.siteLinks.${site};
          holders = lib.attrNames (sites.${site}.loopbacks or { });
        in
        lib.length (lib.attrNames ends) == 2
        && lib.all (machine: lib.elem machine holders) (lib.attrNames ends)
        && isUnique (lib.mapAttrsToList (_: end: end.interface) ends)
      ) (lib.attrNames inventory.siteLinks);
      message = "an inventory site link must have two ends, each a loopback holder at that site, on distinct interfaces";
    }
    {
      assertion = lib.attrNames inventory.anycast4 == lib.attrNames inventory.anycast6;
      message = "inventory anycast4 and anycast6 must name the same services";
    }
    {
      assertion = lib.all (
        svc:
        lib.last (lib.splitString "." inventory.anycast4.${svc})
        == lib.last (lib.splitString ":" (inventory.anycast6.${svc} or ""))
      ) (lib.attrNames inventory.anycast4);
      message = "an inventory anycast service's IPv4 last octet must match its IPv6 last hextet";
    }

    # Prefix layout.
    {
      assertion = lib.all carveOutValid carveOuts;
      message = "inventory ULA carve-outs must be compressed /56s of ulaPrefix6";
    }
    {
      assertion = isUnique (map carveOutHextet (lib.filter carveOutValid carveOuts));
      message = "inventory ULA carve-outs must be distinct";
    }
    {
      # Carve-outs number down from the top and sites up from the bottom.
      assertion = lib.all (
        p: lib.all (s: lib.fromHexString "${carveOutHextet p}00" > siteTopHextet s) (lib.attrValues sites)
      ) (lib.filter carveOutValid carveOuts);
      message = "inventory ULA carve-outs must sit above every site's subnets";
    }
    {
      assertion = lib.all (cidr: (range4 cidr).aligned && contains4 inventory.privatePrefix4 cidr) (
        blocks4 ++ [ inventory.anycastPrefix4 ]
      );
      message = "inventory IPv4 blocks must be aligned prefixes inside privatePrefix4";
    }
    {
      assertion = lib.all (pair: !(overlaps4 (lib.elemAt pair 0) (lib.elemAt pair 1))) blockPairs4;
      message = "inventory IPv4 blocks must not overlap: the site /16s, loopbackPrefix4, circuitPrefix4, labPrefix4, cloudPrefix4";
    }
    {
      assertion = contains4 inventory.loopbackPrefix4 inventory.anycastPrefix4;
      message = "inventory anycastPrefix4 must sit inside loopbackPrefix4, site 00";
    }
    {
      assertion = lib.all (
        lo: lo.addr4 == null || !(contains4 inventory.anycastPrefix4 "${lo.addr4}/32")
      ) (map (lo: { addr4 = lo.addr4 or null; }) siteLoopbacks);
      message = "inventory loopback IPv4 addresses must not fall in anycastPrefix4";
    }
  ];
}
