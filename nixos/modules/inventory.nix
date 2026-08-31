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

  allKeys = [
    "site/ula_prefix"
  ]
  ++ lib.concatLists (
    lib.mapAttrsToList (
      name: subnet: subnetKeys name ++ lib.concatLists (lib.mapAttrsToList hostKeys (subnet.hosts or { }))
    ) inventory.subnets
  );

  mkHost =
    ifi: name: host:
    let
      mode = host.ipv6 or null;
      iid = suffix: placeholder "hosts/${name}/${suffix}";
    in
    {
      inherit name;
      interface = ifi.name;
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
        inherit (subnet) vlan trusted;
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

  interfaces = lib.mapAttrs mkInterface inventory.subnets;
in
{
  options.homelab.inventory = lib.mkOption {
    type = lib.types.raw;
    readOnly = true;
    description = ''
      Network inventory with addresses as sops placeholders. ulaPrefix is the
      site's ULA /48 (first three groups). Interfaces carry the router's
      addresses and prefixes plus their hosts; hosts carry mac, ipv4, and
      ula/gua (null when the host has no known IPv6 address).
    '';
  };

  config = {
    homelab.inventory = {
      inherit (inventory) domain roles;
      inherit interfaces;
      ulaPrefix = placeholder "site/ula_prefix";
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
