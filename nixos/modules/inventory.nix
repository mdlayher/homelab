# Exposes the network inventory (nixos/inventory/) to modules as
# config.homelab.inventory. The structure comes from nixos/inventory/default.nix;
# every address and MAC is a sops placeholder for a value in
# nixos/inventory/secrets.yaml, so consumers must render it through
# sops.templates rather than into the Nix store. Prefixes are plain data
# built from the site index and VLAN, except a subnet's GUA prefix, which
# the ISP delegates.
{
  config,
  inventory,
  lib,
  ...
}:

let
  sopsFile = ../inventory/secrets.yaml;

  # Secret names are namespaced to avoid clashing with per-machine secrets.
  secretName = key: "inventory/${key}";
  placeholder = key: config.sops.placeholder.${secretName key};

  # This machine's site, and the parts of the inventory belonging to it. A
  # machine only ever configures its own site, so what it sees is scoped to
  # one; the domains of every site are exposed separately for consumers which
  # name hosts elsewhere, such as the server's Prometheus.
  site = config.homelab.site;
  siteCfg = inventory.sites.${site};
  subnets = siteCfg.subnets or { };
  domain = "${site}.${inventory.zone}";

  # Interface identifier secret keys needed for a host's IPv6 mode.
  iidKeys =
    name: host:
    let
      mode = host.ipv6 or null;
    in
    if mode == "prefixstable" then
      [ "hosts/${name}/iid_ula" ]
    else if mode != null then
      [ "hosts/${name}/iid" ]
    else
      [ ];

  hostKeys =
    name: host:
    [
      "hosts/${name}/mac"
      "hosts/${name}/ipv4"
    ]
    ++ iidKeys name host;

  allKeys =
    lib.concatLists (
      lib.mapAttrsToList (
        name: subnet:
        lib.concatLists (lib.mapAttrsToList hostKeys (subnet.hosts or { }))
      ) subnets
    )
    # The private DNS zones the router answers itself, space-separated; see
    # the router host's coredns.nix. Declared only where there are subnets to
    # serve, so a site with no LAN decrypts nothing from this file.
    ++ lib.optional (subnets != { }) "private_zones";

  mkHost =
    ifi: name: host:
    let
      mode = host.ipv6 or null;
      iid = suffix: placeholder "hosts/${name}/${suffix}";
    in
    {
      inherit name;
      interface = ifi.name;
      # The name DNS publishes and Prometheus scrapes, namespaced by the
      # segment's role. `name` stays the bare inventory key, which is what
      # sops keys and DHCP static leases are built from.
      dnsName = "${name}.${ifi.role}";
      mac = placeholder "hosts/${name}/mac";
      ipv4 = placeholder "hosts/${name}/ipv4";
      ula =
        if mode == "prefixstable" then
          "${ifi.ulaPrefix}:${iid "iid_ula"}"
        else if mode != null then
          "${ifi.ulaPrefix}:${iid "iid"}"
        else
          null;
      # The interface identifier alone, for a rule matching a host under
      # whatever prefix it currently holds. Null when the host has no single
      # one: an RFC 7217 identifier is computed per prefix, so a prefixstable
      # host has a different identifier in each.
      iid = if mode == null || mode == "prefixstable" then null else iid "iid";
    };

  mkInterface =
    name: subnet:
    let
      # The fourth hextet of the ULA and the third octet of the IPv4 prefix
      # read as decimal SSVV and S.V, site index then VLAN, the layout
      # described in nixos/inventory/default.nix. Written compressed, as
      # every address built from them is.
      ulaPrefix = "${lib.removeSuffix "::/48" inventory.ulaPrefix6}:${
        toString (100 * siteCfg.index + subnet.vlan)
      }";
      ipv4Prefix = "${lib.removeSuffix "0.0.0/8" inventory.privatePrefix4}${toString siteCfg.index}.${toString subnet.vlan}";
      ifi = {
        inherit name;
        inherit (subnet) vlan trusted role;
        # Untrusted, but permitted to originate ICMP diagnostics past its
        # own segment: see routnerr-3/nftables.nix.
        debug = subnet.debug or false;
        # The search domain this segment is handed, and the namespace its
        # hosts are named in.
        searchDomain = "${subnet.role}.${domain}";
        # All subnets have medium router preference by default.
        preference = subnet.preference or "medium";

        # Router addresses: always .1 and ::1.
        inherit ipv4Prefix ulaPrefix;
        ipv4 = "${ipv4Prefix}.1";
        ula = "${ulaPrefix}::1";
        lla = "fe80::1";

        hosts = lib.mapAttrsToList (mkHost ifi) (subnet.hosts or { });
      };
    in
    ifi;

  interfaces = lib.mapAttrs mkInterface subnets;

  hostNames = lib.concatMap (ifi: map (h: h.name) ifi.hosts) (lib.attrValues interfaces);

  # A router loopback, keyed by the machine's name. Plain data throughout,
  # unlike everything above: a loopback is named and read across sites, and a
  # sops placeholder only means anything on the machine which declared the
  # secret. dnsName is null where the machine is not published at it.
  #
  # The loopback a site's fabric is reached at, by the roles registry: the
  # router's where the site has one, the edge's otherwise. One per site,
  # since the name it answers says the site and nothing more.
  siteAnchor =
    s:
    let
      names = lib.attrNames (s.loopbacks or { });
      holder = role: lib.findFirst (n: lib.elem n names) null inventory.roles.${role};
    in
    if holder "router" != null then holder "router" else holder "edge";

  # siteFqdn is a fixed shape the anchor loopback answers to, so the address
  # a site's fabric is reached at is found the same way at every site. Null
  # on any other loopback there.
  mkLoopback =
    siteDomain: anchor: name: lo:
    let
      dnsName = lo.dnsName or null;
    in
    {
      inherit name dnsName;
      addr6 = lo.addr6;
      addr4 = lo.addr4 or null;
      fqdn = if dnsName == null then null else "${dnsName}.${siteDomain}";
      siteFqdn = if name == anchor then "site.${siteDomain}" else null;
    };

  siteLoopbacks =
    name: s: lib.mapAttrs (mkLoopback "${name}.${inventory.zone}" (siteAnchor s)) (s.loopbacks or { });

  # A site's own /56 out of the ULA, from its index: the fourth hextet reads
  # as decimal SSVV, so a site's space runs from its index with VLAN 00. This
  # is what a site originates into the IGP on its own behalf.
  sitePrefix6 =
    index: "${lib.removeSuffix "::/48" inventory.ulaPrefix6}:${lib.fixedWidthNumber 2 index}00::/56";

  # The same in IPv4: a site's /16 is its index in the second octet.
  sitePrefix4 =
    index: "${lib.removeSuffix "0.0.0/8" inventory.privatePrefix4}${toString index}.0.0/16";

  loopbacks = siteLoopbacks site siteCfg;

  allLoopbacks = lib.concatMap lib.attrValues (
    lib.attrValues (lib.mapAttrs siteLoopbacks inventory.sites)
  );

  # loopbackPrefix6 without its length, for the containment check below: a
  # loopback is written compressed, so the prefix is a literal string prefix
  # of every address drawn from it. A prefix written in another form keeps
  # its length here and matches nothing, so the assertion trips rather than
  # quietly stopping checking.
  loopbackBase = lib.removeSuffix "/64" inventory.loopbackPrefix6;

  # The same, for the anycast addresses.
  anycastBase = lib.removeSuffix "/64" inventory.anycastPrefix6;
in
{
  options.homelab.site = lib.mkOption {
    type = lib.types.enum (lib.attrNames inventory.sites);
    description = ''
      The site this machine is at, naming its entry in the inventory. No
      default: a default is how a machine at a new site silently inherits
      another's domain and addressing.
    '';
  };

  options.homelab.inventory = lib.mkOption {
    type = lib.types.raw;
    readOnly = true;
    description = ''
      Network inventory with addresses as sops placeholders. The prefixes
      are the exception and are plain data, since each names a range rather
      than an address: ulaPrefix6 and privatePrefix4, the spaces every site is
      drawn from, each interface's ULA and IPv4 prefix built from those by
      site index and VLAN (its GUA prefix stays a placeholder), and the
      carve-outs from the ULA -- labPrefix6,
      carrierPrefix6, loopbackPrefix6, circuitPrefix6, locatorPrefix6 and
      anycastPrefix6, plus
      anycast, the service address drawn from that last one for each
      service answered at every site. So are dn42, its whole space and
      our allocation in it, and isis, the area
      and per-router system IDs. See nixos/inventory/ for what each covers.
      Scoped to this machine's homelab.site: domain, interfaces, hosts and
      loopbacks are that site's alone, while sites carries every site's
      index, domain, prefix and loopbacks. A site's
      index is the number every addressing scheme keys on, its prefix is the
      /56 built from that index, and the identifier of a link between two
      sites is their pair of indices.
      Interfaces carry the router's addresses and prefixes, their role and
      searchDomain, plus their hosts; hosts carry mac, ipv4, ula and iid
      (both null when the host has no known IPv6 address, and iid also where
      the identifier differs per prefix) and dnsName, the name DNS
      publishes. privateZones is the space-separated private DNS zone list,
      null at a site with no subnets.
      Loopbacks are keyed by machine name and are plain data, since they are
      read across sites: each carries addr, siteFqdn (null except on the
      one loopback a site's fabric is reached at), and dnsName with the
      fqdn built from it, both null where the machine is not published at
      its loopback.
    '';
  };

  config = {
    assertions = [
      {
        assertion = hostNames == lib.unique hostNames;
        message = "inventory host names must be unique across a site's subnets";
      }
      {
        assertion = lib.all (lo: lib.hasPrefix loopbackBase lo.addr6) allLoopbacks;
        message = "inventory loopback addresses must come from loopbackPrefix6";
      }
      {
        assertion = lib.all (addr: lib.hasPrefix anycastBase addr) (lib.attrValues inventory.anycast6);
        message = "inventory anycast addresses must come from anycastPrefix6";
      }
      {
        assertion = lib.all (addr: lib.hasPrefix (lib.removeSuffix "0/24" inventory.anycastPrefix4) addr) (
          lib.attrValues inventory.anycast4
        );
        message = "inventory anycast4 addresses must come from anycastPrefix4";
      }
      {
        assertion = lib.all (
          lo: lo.addr4 == null || lib.hasPrefix (lib.removeSuffix "0.0/16" inventory.loopbackPrefix4) lo.addr4
        ) allLoopbacks;
        message = "inventory loopback IPv4 addresses must come from loopbackPrefix4";
      }
      {
        # Every site prefix is cut from this string, so a ULA written any
        # other way would silently produce prefixes that are not inside it.
        assertion = lib.hasSuffix "::/48" inventory.ulaPrefix6;
        message = "inventory ulaPrefix6 must be written as a compressed /48, since site prefixes are built from it";
      }
      {
        # A subnet's prefixes spell the VLAN in two decimal digits after
        # the site index, so a larger id would run into the site's.
        assertion = lib.all (subnet: subnet.vlan < 100) (lib.attrValues subnets);
        message = "inventory subnet VLAN ids must be below 100, since subnet prefixes spell them in two digits";
      }
    ];

    homelab.inventory = {
      inherit (inventory)
        roles
        services
        tailnetDomain
        zone
        ;
      inherit domain;
      # Every site's domain and loopbacks, for consumers naming a machine at
      # another one: the router answering for a site it is not at, and the
      # server qualifying a scrape target.
      sites = lib.mapAttrs (name: s: {
        inherit (s) index;
        domain = "${name}.${inventory.zone}";
        prefix6 = sitePrefix6 s.index;
        prefix4 = sitePrefix4 s.index;
        loopbacks = siteLoopbacks name s;
      }) inventory.sites;
      inherit interfaces loopbacks;
      # Plain data, not placeholders; see the notes in the inventory.
      inherit (inventory)
        ulaPrefix6
        privatePrefix4
        labPrefix6
        labPrefix4
        carrierPrefix6
        circuitPrefix6
        circuitPrefix4
        cloudPrefix4
        locatorPrefix6
        dn42
        siteLinks
        loopbackPrefix6
        loopbackPrefix4
        anycastPrefix6
        anycastPrefix4
        anycast6
        anycast4
        isis
        ;
      privateZones = if subnets == { } then null else placeholder "private_zones";
      hosts = lib.listToAttrs (
        lib.concatMap (ifi: map (h: lib.nameValuePair h.name h) ifi.hosts) (lib.attrValues interfaces)
      );
    };

    sops.secrets = lib.listToAttrs (
      map (
        key:
        lib.nameValuePair (secretName key) {
          inherit sopsFile;
          inherit key;
        }
      ) allKeys
    );
  };
}
