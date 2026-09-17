# Exposes the network inventory (nixos/inventory/) to modules as
# config.homelab.inventory. The structure comes from nixos/inventory/default.nix;
# every address, prefix, and MAC is a sops placeholder for a value in
# nixos/inventory/secrets.yaml, so consumers must render it through
# sops.templates rather than into the Nix store.
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

  subnetKeys = name: [
    "subnets/${name}/ipv4_prefix"
    "subnets/${name}/ula_prefix"
    "subnets/${name}/gua_prefix"
  ];

  # Interface identifier secret keys needed for a host's IPv6 mode.
  iidKeys =
    name: host:
    let
      mode = host.ipv6 or null;
    in
    if mode == "prefixstable" then
      [
        "hosts/${name}/iid_ula"
        "hosts/${name}/iid_gua"
      ]
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
        name: subnet: subnetKeys name ++ lib.concatLists (lib.mapAttrsToList hostKeys (subnet.hosts or { }))
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
      gua =
        if mode == "prefixstable" then
          "${ifi.guaPrefix}:${iid "iid_gua"}"
        else if mode != null then
          "${ifi.guaPrefix}:${iid "iid"}"
        else
          null;
    };

  mkInterface =
    name: subnet:
    let
      ipv4Prefix = placeholder "subnets/${name}/ipv4_prefix";
      ulaPrefix = placeholder "subnets/${name}/ula_prefix";
      guaPrefix = placeholder "subnets/${name}/gua_prefix";
      ifi = {
        inherit name;
        inherit (subnet) vlan trusted role;
        # The search domain this segment is handed, and the namespace its
        # hosts are named in.
        searchDomain = "${subnet.role}.${domain}";
        # All subnets have medium router preference by default.
        preference = subnet.preference or "medium";

        # Router addresses: always .1 and ::1.
        inherit ipv4Prefix ulaPrefix guaPrefix;
        ipv4 = "${ipv4Prefix}.1";
        ula = "${ulaPrefix}::1";
        gua = "${guaPrefix}::1";
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
  # secret. dnsName is null where the loopback is not published.
  mkLoopback =
    siteDomain: name: lo:
    let
      dnsName = lo.dnsName or null;
    in
    {
      inherit name dnsName;
      inherit (lo) addr;
      fqdn = if dnsName == null then null else "${dnsName}.${siteDomain}";
    };

  siteLoopbacks = name: s: lib.mapAttrs (mkLoopback "${name}.${inventory.zone}") (s.loopbacks or { });

  loopbacks = siteLoopbacks site siteCfg;

  allLoopbacks = lib.concatMap lib.attrValues (
    lib.attrValues (lib.mapAttrs siteLoopbacks inventory.sites)
  );

  # The first 56 bits of loopbackPrefix, for the containment check below. A
  # prefix written in another form leaves this as the whole CIDR, so the
  # assertion trips rather than quietly stopping checking.
  loopbackHextets = lib.removeSuffix "00::/56" inventory.loopbackPrefix;
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
      Network inventory with addresses as sops placeholders, except
      ulaPrefix, privatePrefix, labPrefix, interconnectPrefix and
      loopbackPrefix: the site's ULA /48, the RFC 1918 space its LANs are
      drawn from, a /56 of the ULA set aside for lab use, a /56 for
      interconnect carriers, and a /56 for router loopbacks, all in CIDR
      notation as plain data, and isis, the area and per-router system IDs.
      Scoped to this machine's homelab.site: domain, aliasDomains,
      interfaces, hosts and loopbacks are that site's alone, while sites
      carries every site's domain and loopbacks.
      Interfaces carry the router's addresses and prefixes, their role and
      searchDomain, plus their hosts; hosts carry mac, ipv4, ula/gua (null
      when the host has no known IPv6 address) and dnsName, the name DNS
      publishes. privateZones is the space-separated private DNS zone list,
      null at a site with no subnets.
      Loopbacks are keyed by machine name and are plain data, since they are
      read across sites: each carries addr, and dnsName with the fqdn built
      from it, both null where the loopback is not published.
    '';
  };

  config = {
    assertions = [
      {
        assertion = hostNames == lib.unique hostNames;
        message = "inventory host names must be unique across a site's subnets";
      }
      {
        assertion = lib.all (lo: lib.hasPrefix loopbackHextets lo.addr) allLoopbacks;
        message = "inventory loopback addresses must come from loopbackPrefix";
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
      aliasDomains = siteCfg.aliasDomains or [ ];
      # Every site's domain and loopbacks, for consumers naming a machine at
      # another one: the router answering for a site it is not at, and the
      # server qualifying a scrape target.
      sites = lib.mapAttrs (name: s: {
        domain = "${name}.${inventory.zone}";
        loopbacks = siteLoopbacks name s;
      }) inventory.sites;
      inherit interfaces loopbacks;
      # Plain data, not placeholders; see the notes in the inventory.
      inherit (inventory)
        ulaPrefix
        privatePrefix
        labPrefix
        interconnectPrefix
        loopbackPrefix
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
