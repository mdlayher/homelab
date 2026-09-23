# A read-only NetBox mirror of the inventory. The repository stays the
# source of truth: netbox-sync writes what the inventory describes on every
# deploy that changes it and deletes what it no longer describes, so the
# database holds nothing that cannot be recreated from the tree.
#
# Anonymous viewers may read everything and nobody is expected to log in.
# The UI is reachable only on the tailnet, at netbox.<tailnet>.
{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:

let
  inventory = config.homelab.inventory;
  cfg = config.services.netbox;

  host = "netbox.${inventory.tailnetDomain}";

  # nginx serves /static itself and proxies the rest to gunicorn; tailscale
  # serve fronts nginx.
  proxyPort = 8081;

  # The machines this flake configures, by the role the inventory gives each.
  roleOf = lib.listToAttrs (
    lib.concatLists (lib.mapAttrsToList (role: map (name: lib.nameValuePair name role)) inventory.roles)
  );
  machines = lib.mapAttrs (name: _: inputs.self.nixosConfigurations.${name}.config) roleOf;

  # The router's VLANs are the segments inventory hosts sit on, so those
  # hosts are at the router's site.
  lanSite = machines.${lib.head inventory.roles.router}.homelab.site;
  lanDomain = inventory.sites.${lanSite}.domain;

  address =
    addr: len: extra:
    lib.optional (addr != null) ({ address = "${addr}/${len}"; } // extra);

  # One record per interface; the sync script groups them by device.
  hostInterfaces = lib.mapAttrsToList (_: h: {
    device = h.name;
    name = h.interface;
    inherit (h) mac;
    addresses =
      address h.ipv4 "24" { dns = "${h.dnsName}.${lanDomain}"; }
      ++ address h.ula "64" { dns = "${h.dnsName}.${lanDomain}"; };
  }) inventory.hosts;

  gatewayInterfaces = lib.mapAttrsToList (_: ifi: {
    device = lib.head inventory.roles.router;
    inherit (ifi) name;
    mac = null;
    addresses = address ifi.ipv4 "24" { } ++ address ifi.ula "64" { };
  }) inventory.interfaces;

  loopbackInterfaces = lib.mapAttrsToList (_: lo: {
    device = lo.name;
    name = "lo";
    mac = null;
    addresses =
      address lo.addr4 "32" {
        role = "loopback";
        dns = lo.fqdn;
      }
      ++ address lo.addr6 "128" {
        role = "loopback";
        dns = lo.fqdn;
      };
  }) inventory.loopbacks;

  dn42Interfaces = lib.concatLists (
    lib.mapAttrsToList (
      name: c:
      lib.optional (c.homelab ? dn42 && c.homelab.dn42.addr4 != null) {
        device = name;
        name = "dn42";
        mac = null;
        addresses = address c.homelab.dn42.addr4 "32" { } ++ address c.homelab.dn42.addr6 "128" { };
      }
    ) machines
  );

  circuitInterfaces = lib.concatLists (
    lib.mapAttrsToList (
      name: c:
      lib.mapAttrsToList (_: link: {
        device = name;
        name = link.interface;
        mac = null;
        addresses = [
          { address = link.localCircuitAddress4; }
          { address = link.localCircuitAddress6; }
        ];
        circuit = {
          inherit (link) site plane;
          local = c.homelab.site;
        };
      }) (c.homelab.interconnect.links or { })
    ) machines
  );

  # dn42 peers by ASN, with the machines and tunnels each one reaches us on.
  dn42Peers = lib.concatLists (
    lib.mapAttrsToList (
      name: c:
      lib.mapAttrsToList (peer: p: {
        inherit peer;
        inherit (p) asn interface;
        device = name;
      }) (c.homelab.dn42.peers or { })
    ) machines
  );

  # The inventory as the sync script reads it, rendered by sops since host
  # addresses and MACs are secret.
  desired = builtins.toJSON {
    devices =
      lib.mapAttrsToList (name: role: {
        inherit name role;
        site = machines.${name}.homelab.site;
        isis = inventory.isis.systemIds.${name} or null;
      }) roleOf
      ++ map (h: {
        inherit (h) name;
        role = "host";
        site = lanSite;
        isis = null;
      }) (lib.filter (h: !(roleOf ? ${h.name})) (lib.attrValues inventory.hosts));

    interfaces =
      hostInterfaces ++ gatewayInterfaces ++ loopbackInterfaces ++ dn42Interfaces ++ circuitInterfaces;

    anycast =
      lib.mapAttrsToList (name: addr: {
        address = "${addr}/32";
        inherit name;
      }) inventory.anycast4
      ++ lib.mapAttrsToList (name: addr: {
        address = "${addr}/128";
        inherit name;
      }) inventory.anycast6;

    asn = machines.${lib.head inventory.roles.router}.homelab.dn42.asn;
    peers = dn42Peers;

    sites = lib.mapAttrsToList (name: site: {
      inherit name;
      inherit (site) domain prefix4 prefix6;
    }) inventory.sites;

    prefixes =
      lib.mapAttrsToList (name: prefix: { inherit name prefix; }) (
        lib.filterAttrs (name: _: builtins.match ".*Prefix[46]" name != null) inventory
      )
      ++ [
        {
          name = "dn42 net4";
          prefix = inventory.dn42.net4;
        }
        {
          name = "dn42 net6";
          prefix = inventory.dn42.net6;
        }
      ];

    # The inventory writes the untagged segment as VLAN 0, which NetBox
    # cannot hold; it is recorded as VLAN 1, the untagged default.
    vlans = lib.mapAttrsToList (_: ifi: {
      inherit (ifi) name role;
      vid = if ifi.vlan == 0 then 1 else ifi.vlan;
      prefix4 = "${ifi.ipv4Prefix}.0/24";
      prefix6 = "${ifi.ulaPrefix}::/64";
    }) inventory.interfaces;
  };

  netboxManage = lib.findFirst (
    p: (p.name or "") == "netbox-manage"
  ) (throw "netbox-manage missing from systemPackages") config.environment.systemPackages;
in
{
  services.netbox = {
    enable = true;
    package = pkgs.netbox_4_5;
    listenAddress = "127.0.0.1";
    secretKeyFile = config.sops.secrets."netbox/secret_key".path;
    apiTokenPeppersFile = config.sops.secrets."netbox/api_token_pepper".path;
    settings = {
      ALLOWED_HOSTS = [ host ];
      CSRF_TRUSTED_ORIGINS = [ "https://${host}" ];
      LOGIN_REQUIRED = false;
      EXEMPT_VIEW_PERMISSIONS = [ "*" ];
    };
  };

  sops.templates."netbox-inventory.json" = {
    content = desired;
    owner = "netbox";
    restartUnits = [ "netbox-sync.service" ];
  };

  # A fresh cluster rather than the server's stateVersion default.
  services.postgresql.package = pkgs.postgresql_18;

  sops.secrets = lib.genAttrs [ "netbox/secret_key" "netbox/api_token_pepper" ] (_: {
    owner = "netbox";
    restartUnits = [ "netbox.service" ];
  });

  services.nginx = {
    enable = true;
    virtualHosts.${host} = {
      listen = [
        {
          addr = "127.0.0.1";
          port = proxyPort;
        }
      ];
      locations."/static/".alias = "${cfg.dataDir}/static/";
      locations."/".proxyPass = "http://${cfg.listenAddress}:${toString cfg.port}";
      locations."/".recommendedProxySettings = true;
    };
  };

  # nginx reads the collected static files from NetBox's state directory.
  users.users.nginx.extraGroups = [ "netbox" ];

  homelab.tailscale.services.netbox = {
    "tcp:80" = "http://127.0.0.1:${toString proxyPort}";
    "tcp:443" = "tls-terminated-tcp://127.0.0.1:${toString proxyPort}";
  };

  # Restarted by sops-nix whenever the rendered inventory changes.
  systemd.services.netbox-sync = {
    description = "Mirror the inventory into NetBox";
    after = [
      "netbox.service"
      "postgresql.service"
    ];
    requires = [
      "netbox.service"
      "postgresql.service"
    ];
    wantedBy = [ "multi-user.target" ];
    environment.NETBOX_SYNC_INPUT = config.sops.templates."netbox-inventory.json".path;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "netbox";
      WorkingDirectory = cfg.dataDir;
    };
    # netbox.service migrates only when the NetBox version changes, so a
    # fresh database is migrated here; on a current one this does nothing.
    script = ''
      ${netboxManage}/bin/netbox-manage migrate --no-input
      ${netboxManage}/bin/netbox-manage shell --no-imports -c "$(cat ${./netbox-sync.py})"
    '';
  };
}
