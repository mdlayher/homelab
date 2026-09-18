{
  config,
  lib,
  pkgs,
  ...
}:

let
  inventory = config.homelab.inventory;

  hostName = config.networking.hostName;

  # Names a host answers to for one address family. The site domain carries
  # the role-labelled scheme, with the family pin leading as it does in the
  # dn42 and clearnet zones. Each retired domain carries both the labelled
  # and the unlabelled name, which together cover every shape in use before
  # the move, so nothing hardcoded off-repo breaks until it is dropped.
  names =
    host: family:
    [
      "${host.dnsName}.${inventory.domain}"
      "${family}.${host.dnsName}.${inventory.domain}"
    ]
    ++ lib.concatMap (d: [
      "${host.dnsName}.${d}"
      "${host.name}.${d}"
    ]) inventory.aliasDomains;

  # Internal DNS records for each host, as a hosts file rendered from the
  # inventory secrets. Hosts without a known IPv6 address get an A record
  # only.
  hostsFile = lib.concatMapStrings (
    host:
    lib.concatMapStrings (n: "${host.ipv4} ${n}\n") (names host "ipv4")
    + lib.optionalString (host.ula != null) (
      lib.concatMapStrings (n: "${host.ula} ${n}\n") (names host "ipv6")
    )
  ) (lib.attrValues inventory.hosts);

  # The router answers on every LAN it serves, one name per interface, so a
  # reverse lookup resolves back to the address it was asked about. Under a
  # retired domain it keeps the single home-VLAN name it has now rather than
  # gaining an address per segment behind one name.
  routerFile =
    lib.concatMapStrings (
      ifi:
      let
        n = "${hostName}.${ifi.role}";
      in
      ''
        ${ifi.ipv4} ${n}.${inventory.domain}
        ${ifi.ipv4} ipv4.${n}.${inventory.domain}
        ${ifi.ula} ${n}.${inventory.domain}
        ${ifi.ula} ipv6.${n}.${inventory.domain}
      ''
      + lib.concatMapStrings (d: ''
        ${ifi.ipv4} ${n}.${d}
        ${ifi.ula} ${n}.${d}
      '') inventory.aliasDomains
    ) (lib.attrValues inventory.interfaces)
    # Being on every segment, the router needs a defined answer for its bare
    # name; the management LAN is it. Forward only, as the family pins are:
    # each address still reverses to its own interface's name.
    + ''
      ${inventory.interfaces.mgmt0.ipv4} ${hostName}.${inventory.domain}
      ${inventory.interfaces.mgmt0.ula} ${hostName}.${inventory.domain}
    ''
    + lib.concatMapStrings (d: ''
      ${inventory.interfaces.lan0.ipv4} ${hostName}.${d}
      ${inventory.interfaces.lan0.ula} ${hostName}.${d}
    '') inventory.aliasDomains;

  # Stable service names: <service>.svc.<zone> resolves to the primary holder
  # of the service's role, so devices which cannot join the tailnet may
  # hardcode a name that follows the service across hardware generation
  # swaps; see nixos/inventory/default.nix. A name resolves to the primary
  # alone: clients cut over when the role's holder list is reordered, never
  # round-robin across generations.
  #
  # Beneath the zone rather than a site, because roles are network-wide: a
  # service moving between sites must not change the name its clients hold,
  # and those clients are the ones hardest to reconfigure.
  servicesFile = lib.concatMapStrings (
    service:
    let
      host = inventory.hosts.${lib.head inventory.roles.${service.value}};
      svcNames = [
        "${service.name}.svc.${inventory.zone}"
      ]
      ++ map (d: "${service.name}.svc.${d}") inventory.aliasDomains;
    in
    lib.concatMapStrings (n: "${host.ipv4} ${n}\n") svcNames
    + lib.optionalString (host.ula != null) (lib.concatMapStrings (n: "${host.ula} ${n}\n") svcNames)
  ) (lib.attrsToList inventory.services);

  # A loopback answers the fixed site name every one of them carries, and
  # its own name where the machine is published at it.
  loopbackForward =
    lo: "${lo.addr} ${lo.siteFqdn}\n" + lib.optionalString (lo.fqdn != null) "${lo.addr} ${lo.fqdn}\n";

  # One name per address in reverse, as the LANs are below: the machine's
  # own where it has one, since that is what a trace should show.
  loopbackReverse = lo: "${lo.addr} ${if lo.fqdn != null then lo.fqdn else lo.siteFqdn}\n";

  siteLoopbacks = site: lib.attrValues site.loopbacks;

  # This site's own loopbacks, answered by the internal zone block as the
  # other sites' are answered beneath theirs. The address is on no segment,
  # so nothing else in the hosts file carries it.
  localLoopbackFile = lib.concatMapStrings loopbackForward (
    siteLoopbacks inventory.sites.${config.homelab.site}
  );

  credential = "hosts";

  # PTRs for the LANs: the inventory hosts and the router's address on
  # every LAN, one name per address. Rendered apart from the hosts file,
  # whose aliases would each become a PTR too.
  ptrFile =
    lib.concatMapStrings (
      host:
      "${host.ipv4} ${host.dnsName}.${inventory.domain}\n"
      + lib.optionalString (host.ula != null) "${host.ula} ${host.dnsName}.${inventory.domain}\n"
    ) (lib.attrValues inventory.hosts)
    + lib.concatMapStrings (ifi: ''
      ${ifi.ipv4} ${hostName}.${ifi.role}.${inventory.domain}
      ${ifi.ula} ${hostName}.${ifi.role}.${inventory.domain}
    '') (lib.attrValues inventory.interfaces)
    + lib.concatMapStrings loopbackReverse (siteLoopbacks inventory.sites.${config.homelab.site})
    + remotePtrFile;
  ptrCredential = "ptr";

  # Sites other than this one which have a loopback. A site with no LAN has
  # no resolver of its own, so this one answers for it: the records are the
  # far site's, the zone is keyed beneath the same internal zone as
  # everything else, and nothing about a loopback is a secret. Hence a store
  # path rather than a rendered credential, which is also what makes that
  # visible in the Corefile.
  remoteSites = lib.filterAttrs (
    name: site: name != config.homelab.site && site.loopbacks != { }
  ) inventory.sites;

  # One file and one block for all of them, as the internal zone already
  # does with the domains it is retiring: the hosts plugin keeps only the
  # names inside a block's zones, so the split is by zone, not by file.
  remoteHostsFile = pkgs.writeText "coredns-remote-hosts" (
    lib.concatMapStrings (site: lib.concatMapStrings loopbackForward (siteLoopbacks site)) (
      lib.attrValues remoteSites
    )
  );

  # The reverse zones are the whole site ULA, so a remote loopback falls
  # inside them and reverses here too.
  remoteDomains = lib.concatStringsSep " " (lib.mapAttrsToList (_: site: site.domain) remoteSites);

  remotePtrFile = lib.concatMapStrings (
    site: lib.concatMapStrings loopbackReverse (siteLoopbacks site)
  ) (lib.attrValues remoteSites);

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
  # dn42-page.nix). ntp is the NTP service for dn42 peers (see chrony.nix).
  # Owner names are relative to each file's zone, so the
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
    ntp IN A ${dn42.addr4}
    ntp IN AAAA ${dn42.addr6}
    azo IN A ${dn42.addr4}
    azo IN AAAA ${dn42.addr6}
    ipv4.azo IN A ${dn42.addr4}
    ipv6.azo IN AAAA ${dn42.addr6}
  '';
  dn42Rev4Zone = pkgs.writeText "coredns-dn42-rev4.zone" ''
    ${dn42Soa}
    ${ptr4 dn42.addr4} IN PTR azo.${dn42.domain}.
  '';
  dn42Rev6Zone = pkgs.writeText "coredns-dn42-rev6.zone" ''
    ${dn42Soa}
    ${ptr6 dn42.addr6} IN PTR azo.${dn42.domain}.
    ${lib.concatMapStringsSep "\n" (vlan: "${ptr6 vlan.addr6} IN PTR azo.${dn42.domain}.") (
      lib.attrValues dn42.vlans
    )}
  '';
in
{
  sops.templates = {
    "coredns-hosts" = {
      content = hostsFile + routerFile + servicesFile + localLoopbackFile;
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

      # Internal zone, this site's and the domains it is retiring. Never
      # the bare zone above them: the root block forwards that to the
      # clearnet, where the public records live.
      ${lib.concatStringsSep " " ([ inventory.domain ] ++ inventory.aliasDomains)} {
        hosts /run/credentials/coredns.service/${credential}
      }

      # Service names, network-wide rather than this site's, so a service
      # moving sites keeps the name its clients hold. The same file serves
      # it: the hosts plugin keeps only the names inside a block's zones.
      # A block of its own because ownership differs from a site zone's,
      # which a second resolver would have to respect.
      svc.${inventory.zone} {
        hosts /run/credentials/coredns.service/${credential}
      }

      # Other sites. Plain data from the inventory, so a store path rather
      # than a rendered credential: a reader of this file can see that
      # nothing about the far site is secret here.
      ${remoteDomains} {
        hosts ${remoteHostsFile}
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
        hosts /run/credentials/coredns.service/${ptrCredential} ${inventory.domain} ${remoteDomains} ${siteRev} {
          fallthrough
        }
        file ${emptyZone}
      }
    '';
  };
}
