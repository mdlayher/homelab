{
  config,
  lib,
  pkgs,
  ...
}:

let
  inventory = config.homelab.inventory;

  # Internal DNS records for each host and the router itself, as a hosts file
  # rendered from the inventory secrets. Hosts without a known IPv6 address get
  # an A record only.
  hostsFile = lib.concatMapStrings (
    host:
    ''
      ${host.ipv4} ${host.name}.${inventory.domain}
      ${host.ipv4} ${host.name}.ipv4.${inventory.domain}
    ''
    + lib.optionalString (host.ula != null) ''
      ${host.ula} ${host.name}.${inventory.domain}
      ${host.ula} ${host.name}.ipv6.${inventory.domain}
    ''
  ) (lib.attrValues inventory.hosts ++ [ router ]);

  router = {
    name = config.networking.hostName;
    inherit (inventory.interfaces.lan0) ipv4 ula;
  };

  # Stable service names: <service>.svc.<domain> resolves to the primary
  # holder of the service's role, so devices which cannot join the tailnet
  # may hardcode a name that follows the service across hardware generation
  # swaps; see nixos/inventory/default.nix. A name resolves to the primary
  # alone: clients cut over when the role's holder list is reordered, never
  # round-robin across generations.
  servicesFile = lib.concatMapStrings (
    service:
    let
      host = inventory.hosts.${lib.head inventory.roles.${service.value}};
    in
    ''
      ${host.ipv4} ${service.name}.svc.${inventory.domain}
    ''
    + lib.optionalString (host.ula != null) ''
      ${host.ula} ${service.name}.svc.${inventory.domain}
    ''
  ) (lib.attrsToList inventory.services);

  credential = "hosts";

  # PTRs for the LANs: the inventory hosts and the router's address on
  # every LAN, one name per address. Rendered apart from the hosts file,
  # whose aliases would each become a PTR too.
  ptrFile =
    lib.concatMapStrings (
      host:
      "${host.ipv4} ${host.name}.${inventory.domain}\n"
      + lib.optionalString (host.ula != null) "${host.ula} ${host.name}.${inventory.domain}\n"
    ) (lib.attrValues inventory.hosts)
    + lib.concatMapStrings (ifi: ''
      ${ifi.ipv4} ${config.networking.hostName}.${inventory.domain}
      ${ifi.ula} ${config.networking.hostName}.${inventory.domain}
    '') (lib.attrValues inventory.interfaces);
  ptrCredential = "ptr";

  # Private zones: answered NXDOMAIN here, never forwarded or logged. The
  # names are an inventory secret, so the block is rendered rather than
  # written into the Corefile, and carries neither log nor prometheus, which
  # both label their output with the zone. The file plugin rather than
  # template for the same reason: template's match counter is zone-labelled
  # and served by the root zone's endpoint regardless. The zone file uses
  # relative names only, so one file serves every zone without naming any.
  privateZonesCredential = "private-zones";
  privateZonesFile = ''
    ${inventory.privateZones} {
      file ${emptyZone}
    }
  '';

  # A zone with nothing in it: every name beneath is NXDOMAIN, and the
  # relative names let one file serve any zone.
  emptyZone = pkgs.writeText "coredns-empty.zone" ''
    $TTL 3600
    @ IN SOA ns hostmaster 1 7200 3600 1209600 3600
  '';

  # dn42 (see dn42.nix): the registry delegates our domain and reverse
  # space to ns1, whose glue is the router's dn42 addresses. The zones
  # bind those two addresses alone, which nftables.nix opens on port 53;
  # a listener on a specific address takes every query to it, so the
  # wildcard root block never sees dn42, and other names are refused
  # there rather than recursed. All registry data, nothing to render.
  dn42 = config.homelab.dn42;

  # The reverse zones as the delegation servers cut them: RFC 2317 form,
  # 80/28.140.20.172.in-addr.arpa, for the /28; nibble boundary for the /48.
  net4 = lib.splitString "/" dn42.net4;
  octets4 = lib.splitString "." (lib.head net4);
  rev4 = "${lib.last octets4}/${lib.last net4}.${lib.concatStringsSep "." (lib.reverseList (lib.take 3 octets4))}.in-addr.arpa";
  # An address's owner name in that zone: its last octet.
  ptr4 = addr: lib.last (lib.splitString "." addr);

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
  net6 = lib.splitString "/" dn42.net6;
  net6Nibbles = lib.toInt (lib.last net6) / 4;
  rev6 = "${lib.concatStringsSep "." (lib.reverseList (lib.take net6Nibbles (nibbles6 (lib.head net6))))}.ip6.arpa";
  # An address's owner name in that zone: its remaining nibbles.
  ptr6 = addr: lib.concatStringsSep "." (lib.reverseList (lib.drop net6Nibbles (nibbles6 addr)));

  # The site's own reverse zones, answered locally: the ULA /48 from the
  # inventory, and all of RFC 1918 except dn42's 172.20.0.0/14, since the
  # LAN prefixes are secrets and no outside resolver can answer for that
  # space anyway (RFC 6303).
  ula = lib.splitString "/" inventory.ulaPrefix;
  ulaRev = "${
    lib.concatStringsSep "." (
      lib.reverseList (lib.take (lib.toInt (lib.last ula) / 4) (nibbles6 (lib.head ula)))
    )
  }.ip6.arpa";
  siteRev = lib.concatStringsSep " " (
    [
      ulaRev
      "10.in-addr.arpa"
      "168.192.in-addr.arpa"
    ]
    ++ map (n: "${toString n}.172.in-addr.arpa") (lib.range 16 19 ++ lib.range 24 31)
  );

  # The apex is the peering page, with single-family names beneath it as
  # on the clearnet and HTTPS records advertising HTTP/3 on all three;
  # the router's addresses, on the dummy and on the
  # internal VLAN, reverse to azo, the site's name as in
  # azo.dn42.mdlayher.net, whose names redirect to the apex's (see
  # azo-page.nix). Owner names are relative to each file's zone, so the
  # shared SOA and NS are written out in full.
  dn42Soa = ''
    $TTL 3600
    @ IN SOA ns1.${dn42.domain}. hostmaster.${dn42.domain}. 1 7200 3600 1209600 3600
    @ IN NS ns1.${dn42.domain}.
  '';
  dn42Zone = pkgs.writeText "coredns-dn42.zone" ''
    ${dn42Soa}
    @ IN A ${dn42.addr4}
    @ IN AAAA ${dn42.addr6}
    @ IN HTTPS 1 . alpn="h3,h2"
    ipv4 IN A ${dn42.addr4}
    ipv4 IN HTTPS 1 . alpn="h3,h2"
    ipv6 IN AAAA ${dn42.addr6}
    ipv6 IN HTTPS 1 . alpn="h3,h2"
    ns1 IN A ${dn42.addr4}
    ns1 IN AAAA ${dn42.addr6}
    azo IN A ${dn42.addr4}
    azo IN AAAA ${dn42.addr6}
    ipv4.azo IN A ${dn42.addr4}
    ipv6.azo IN AAAA ${dn42.addr6}
  '';
  dn42Rev4Zone = pkgs.writeText "coredns-dn42-rev4.zone" ''
    ${dn42Soa}
    ${ptr4 dn42.addr4} IN PTR azo.${dn42.domain}.
    ${ptr4 dn42.dev0.addr4} IN PTR azo.${dn42.domain}.
  '';
  dn42Rev6Zone = pkgs.writeText "coredns-dn42-rev6.zone" ''
    ${dn42Soa}
    ${ptr6 dn42.addr6} IN PTR azo.${dn42.domain}.
    ${ptr6 dn42.dev0.addr6} IN PTR azo.${dn42.domain}.
  '';
in
{
  sops.templates = {
    "coredns-hosts" = {
      content = hostsFile + servicesFile;
      restartUnits = [ "coredns.service" ];
    };
    "coredns-private-zones" = {
      content = privateZonesFile;
      restartUnits = [ "coredns.service" ];
    };
    "coredns-ptr" = {
      content = ptrFile;
      restartUnits = [ "coredns.service" ];
    };
  };

  systemd.services.coredns = {
    # coredns runs with DynamicUser, so hand it the rendered files via
    # systemd credentials.
    serviceConfig.LoadCredential = [
      "${credential}:${config.sops.templates."coredns-hosts".path}"
      "${privateZonesCredential}:${config.sops.templates."coredns-private-zones".path}"
      "${ptrCredential}:${config.sops.templates."coredns-ptr".path}"
    ];

    # The dn42 zones bind the dn42 dummy's addresses, which networkd adds
    # after network.target: order after the device, and retry without a
    # start limit should they lag, rather than leave the LAN without DNS.
    # Ordering only: the LAN's resolver never depends on dn42.
    after = [ "sys-subsystem-net-devices-dn42.device" ];
    serviceConfig.RestartSec = "2s";
    unitConfig.StartLimitIntervalSec = 0;
  };

  services.coredns = {
    enable = true;
    config = ''
      # Root zone.
      . {
        cache 3600 {
          success 8192
          denial 4096
        }
        prometheus :9153
        # Denials only, never successful lookups: the class covers NXDOMAIN
        # and NODATA, which is the useful half. A device hammering a name
        # that does not resolve, a search domain that never got configured,
        # or an appliance calling home to something that is gone all show up
        # here, at a small fraction of the cost of logging everything. The
        # router answers roughly 1 query per second (see
        # CoreDNSUpstreamFailing), so full query logging would be on the
        # order of 86k lines a day, dwarfing every other journal on this
        # machine - and it would be a browsing history for every device in
        # the house, which is not a thing worth keeping for a year.
        #
        # This block only, not the internal zone below: a name missing from
        # the hosts file is answered SERVFAIL rather than NXDOMAIN, so it is
        # of class error and a log directive there would not see it anyway.
        log . {
          class denial
        }
        forward . tls://8.8.8.8 tls://8.8.4.4 tls://2001:4860:4860::8888 tls://2001:4860:4860::8844 {
          tls_servername dns.google
          health_check 5s
        }
      }

      # Internal zone.
      ${inventory.domain} {
        hosts /run/credentials/coredns.service/${credential}
      }

      # The tailnet: its names exist only in each node's tailscaled, which
      # answers at the virtual resolver address for the peers and services
      # in its netmap. Forwarded to the router's own, so every machine
      # resolves tailnet names through here (see modules/tailscale.nix).
      # The router is tagged infra and router, so its netmap holds every
      # device and service the policy grants the fleet
      # (terraform/tailscale/policy.hujson). No cache: tailscaled answers
      # from memory with a 5 s TTL. Counted like the root zone, so
      # CoreDNSUpstreamFailing notices the router's tailscaled going quiet.
      ${inventory.tailnetDomain} {
        prometheus :9153
        forward . 100.100.100.100
      }

      # Private zones, a server block rendered from the inventory secrets.
      import /run/credentials/coredns.service/${privateZonesCredential}

      # dn42, authoritative, on the ns1 addresses only (see dn42 above).
      # The zone names are public, so the zone-labelled metrics are fine.
      ${dn42.domain} ${rev4} ${rev6} {
        bind ${dn42.addr4} ${dn42.addr6}
        prometheus :9153
        file ${dn42Zone} ${dn42.domain}
        file ${dn42Rev4Zone} ${rev4}
        file ${dn42Rev6Zone} ${rev6}
      }

      # dn42: the forwarders in the root block are on the internet, where
      # no dn42 name exists. Names under dn42 go to its anycast resolvers
      # instead, a0 and a3 of recursive-servers.dn42, which the router
      # reaches from its own dn42 address. For the machines with a dn42
      # interface, the router itself and the development container behind
      # it, both of which resolve through here; any other LAN client that
      # asks gets a name it cannot reach, since the LANs are not routed
      # into dn42.
      # The reverse zones go the same way: 172.20.0.0/14 is dn42's alone,
      # but fd00::/8 is every ULA, so the site's own /48 is answered by the
      # block after this one, whose zones are more specific and win.
      dn42 20.172.in-addr.arpa 21.172.in-addr.arpa 22.172.in-addr.arpa 23.172.in-addr.arpa d.f.ip6.arpa {
        forward . 172.20.0.53 172.23.0.53 fd42:d42:d42:54::1 fd42:d42:d42:53::1
      }

      # The site's reverse zones, never forwarded: PTRs from the inventory,
      # and NXDOMAIN from the empty zone for the rest (file runs after
      # hosts). The hosts plugin keeps only names inside its zones, hence
      # the domain beside the reverse zones; forward queries never arrive
      # here, the block is keyed on the reverse zones alone.
      ${siteRev} {
        hosts /run/credentials/coredns.service/${ptrCredential} ${inventory.domain} ${siteRev} {
          fallthrough
        }
        file ${emptyZone}
      }
    '';
  };
}
