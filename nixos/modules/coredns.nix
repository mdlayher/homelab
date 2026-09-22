# The internal resolver. Every node answering an anycast service address must
# answer identically, so the rendering of each zone lives here rather than at
# one machine: a second node is this module plus whatever is local to it.
#
# A machine may add server blocks of its own; services.coredns.config is
# lines, so its definitions merge with the ones below.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  inventory = config.homelab.inventory;

  # The router's name, from the role rather than this machine's own: the
  # records below are the router's wherever they are rendered.
  routerName = lib.head inventory.roles.router;

  # Names a host answers to for one address family. The site domain carries
  # the role-labelled scheme, with the family pin leading as it does in the
  # dn42 and clearnet zones.
  names = host: family: [
    "${host.dnsName}.${inventory.domain}"
    "${family}.${host.dnsName}.${inventory.domain}"
  ];

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
  # reverse lookup resolves back to the address it was asked about.
  routerFile =
    lib.concatMapStrings (
      ifi:
      let
        n = "${routerName}.${ifi.role}";
      in
      ''
        ${ifi.ipv4} ${n}.${inventory.domain}
        ${ifi.ipv4} ipv4.${n}.${inventory.domain}
        ${ifi.ula} ${n}.${inventory.domain}
        ${ifi.ula} ipv6.${n}.${inventory.domain}
      ''
    ) (lib.attrValues inventory.interfaces)
    # Being on every segment, the router needs a defined answer for its bare
    # name; the management LAN is it. Forward only, as the family pins are:
    # each address still reverses to its own interface's name.
    + ''
      ${inventory.interfaces.mgmt0.ipv4} ${routerName}.${inventory.domain}
      ${inventory.interfaces.mgmt0.ula} ${routerName}.${inventory.domain}
    '';

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
      svcNames = [ "${service.name}.svc.${inventory.zone}" ];
    in
    lib.concatMapStrings (n: "${host.ipv4} ${n}\n") svcNames
    + lib.optionalString (host.ula != null) (lib.concatMapStrings (n: "${host.ula} ${n}\n") svcNames)
  ) (lib.attrsToList inventory.services);

  # A loopback answers the fixed site name where it is the one the site is
  # reached at, and its own name where the machine is published at it. One
  # with neither is reached by address alone.
  loopbackForward =
    lo:
    lib.optionalString (lo.siteFqdn != null) "${lo.addr6} ${lo.siteFqdn}\n"
    + lib.optionalString (lo.fqdn != null) "${lo.addr6} ${lo.fqdn}\n";

  # One name per address in reverse, as the LANs are below: the machine's
  # own where it has one, since that is what a trace should show.
  loopbackReverse =
    lo:
    if lo.fqdn != null then
      "${lo.addr6} ${lo.fqdn}\n"
    else
      lib.optionalString (lo.siteFqdn != null) "${lo.addr6} ${lo.siteFqdn}\n";

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
      ${ifi.ipv4} ${routerName}.${ifi.role}.${inventory.domain}
      ${ifi.ula} ${routerName}.${ifi.role}.${inventory.domain}
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

  # One file and one block for all of them: the hosts plugin keeps only the
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

  # The site's own reverse zones, answered locally: the ULA /48 from the
  # inventory, and all of RFC 1918 except dn42's 172.20.0.0/14, since the
  # LAN prefixes are secrets and no outside resolver can answer for that
  # space anyway (RFC 6303).
  ula = lib.splitString "/" inventory.ulaPrefix6;
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

  inherit (import ./reverse-zones.nix { inherit lib; }) nibbles6;
in
{
  # Answered at every site, so a client reaches the nearest resolver rather
  # than this machine wherever it is (see modules/anycast.nix). Every block
  # below binds the wildcard, so the address appearing on the interface is
  # all this needs.
  homelab.anycast.services.dns.unit = "coredns.service";

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

  # Every block binds the wildcard, which covers the address resolved's stub
  # listener would hold, so the two cannot both have port 53. A machine here
  # turns the stub off and points resolved at the anycast address instead;
  # ordering after it keeps an activation which restarts both from starting
  # this one first and failing to bind.
  systemd.services.coredns.after = [ "systemd-resolved.service" ];

  # nixpkgs gives resolved a reloadTrigger on its configuration, so a change
  # to it is applied with `systemctl reload`, and a reload does not fully
  # re-apply that configuration: a search domain dropped from the file was
  # found still in the running state long afterwards. Whatever the stub
  # listener does on reload, this machine cannot afford to find out during
  # activation, since holding port 53 would keep the resolver from starting
  # at all. Restart instead.
  systemd.services.systemd-resolved.restartTriggers = [
    config.environment.etc."systemd/resolved.conf".source
  ];

  # coredns runs with DynamicUser, so hand it the rendered files via
  # systemd credentials.
  systemd.services.coredns.serviceConfig.LoadCredential = [
    "${credential}:${config.sops.templates."coredns-hosts".path}"
    "${privateZonesCredential}:${config.sops.templates."coredns-private-zones".path}"
    "${ptrCredential}:${config.sops.templates."coredns-ptr".path}"
  ];

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

      # Internal zone, this site's. Never the bare zone above it: the root
      # block forwards that to the clearnet, where the public records live.
      ${inventory.domain} {
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

      # dn42: the forwarders in the root block are on the internet, where
      # no dn42 name exists. Names under dn42 go to its anycast resolvers
      # instead, a0 and a3 of recursive-servers.dn42, reached from this
      # machine's own dn42 address -- so a resolver here has to be a dn42
      # host, which both of them are. A LAN client that asks gets a name it
      # cannot reach, since the LANs are not routed into dn42.
      # The reverse zones go the same way: 172.20.0.0/14 is dn42's alone,
      # but fd00::/8 is every ULA, so the site's own /48 is answered by the
      # site reverse block, whose zones are more specific and win.
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
