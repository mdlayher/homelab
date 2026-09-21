{
  config,
  lib,
  pkgs,
  utils,
  ...
}:

# Links between our own sites: the link itself, not what runs on it.
#
# Imported by the machine which terminates a link, and by nothing else. It
# depends on no other module: a site may have a circuit and carry only its
# own ULA topology across it. dn42 is one of the things that may ride a
# circuit, and asserts this module is present when it does; the dependency
# does not run the other way.
#
# "Link" and "circuit" are not interchangeable here. A link is the medium;
# a circuit is one IGP instance's attachment to it, owning that link's
# hellos and adjacencies (see ~/src/isis CONTEXT.md, which this follows so
# the two repositories speak one language). Everything below is links.
#
# A site interconnect is neither a LAN nor a dn42 tunnel. Both ends are
# ours, so it is trusted the way a LAN is, but it crosses the internet, so
# it is encrypted the way a peering tunnel is. It carries everything that
# moves between sites -- the site ULA, dn42 registry space, loopbacks --
# which is why it does not live in dn42.nix: a dn42 interface may never
# carry the ULA, and its filters and firewall chains enforce that.
#
# Two devices per link, so the inner one has a data link of its own. An IGP
# which runs directly on the link -- IS-IS does -- cannot use WireGuard or
# plain GRE, neither of which has one. An IGP which runs over IP is happy
# either way, so an L2 link is the shape that keeps the choice open.
#
# Named icl for interconnect link, with the carrier taking a w:
#
#   iclw-<site>  the WireGuard carrier. Confidentiality and authentication,
#                a /127 at each end, and nothing else ever rides it.
#   icl-<site>   a GRETAP inside it: the interconnect link proper, and
#                what both routing protocols run on. It is link/ether, which
#                FRR's isisd requires: given link/none (WireGuard) or
#                link/gre it logs "unsupported link layer" and forms no
#                adjacency.
#
# The routing protocols are declared elsewhere. The IGP carries our own
# topology, the ULA included; bird's iBGP carries the dn42 table and
# resolves its next hops through the IGP once that is cut over.

let
  cfg = config.homelab.interconnect;
  inventory = config.homelab.inventory;

  # This router's IS-IS system ID, from the inventory registry keyed by
  # machine name. Null for a machine the registry does not name.
  systemId = inventory.isis.systemIds.${config.networking.hostName} or null;

  # The isisd process tag, which names the area in isisd's own
  # configuration. The area address routers agree on is the NET's first
  # half, from the inventory.
  tag = "core";

  # Two decimal digits, the way every other scheme here writes a site or a
  # VLAN into a hextet.
  pad = lib.fixedWidthNumber 2;

  # A link's identifier is the two sites' indices in ascending order. It is
  # unique to the pair and both ends derive the same value, so a second link
  # cannot land on a first link's addresses and no registry has to be kept
  # in step. The site index is the inventory's, shared with every other
  # scheme that numbers sites.
  linkPair =
    far:
    let
      a = inventory.sites.${config.homelab.site}.index;
      b = inventory.sites.${far}.index;
    in
    "${pad (lib.min a b)}${pad (lib.max a b)}";

  # The /64 a plane's addresses come from, within a /56. A plane is one of
  # several parallel links to the same site, each over a different WAN, so
  # the pair alone no longer identifies a link. Plane 0 takes the first /64,
  # which is what keeps a site's only link at the addresses it already has.
  pool = prefix: plane: "${lib.removeSuffix "00::/56" prefix}${pad plane}::";

  # Whether the end being named is the lower-indexed of the link's two
  # sites. This decides every per-link address, and both ends run it over
  # the same two indices, so each derives the other's addresses as readily
  # as its own and neither has to be told. Which end is which is arbitrary;
  # only the agreement matters. ours selects which of the two is named.
  isLowerEnd =
    far: ours:
    let
      mine = inventory.sites.${config.homelab.site}.index;
      theirs = inventory.sites.${far}.index;
    in
    (if ours then mine else theirs) == lib.min mine theirs;

  # A link's WireGuard listen port: 51<a><b><plane>, where a and b are the
  # two sites' indices in ascending order. Derived from the same pair the
  # addresses are, so both ends reach the same number without being told and
  # two links can never want one port -- which is the whole failure the
  # uniqueness assertion below used to exist to catch.
  #
  # Keying on the pair rather than the far site is what makes a ring work:
  # azo-iad and pdx-iad both have iad at one end, so a scheme reading only
  # the higher index would collide on iad's two links.
  linkPort =
    far: plane:
    let
      a = inventory.sites.${config.homelab.site}.index;
      b = inventory.sites.${far}.index;
    in
    51000 + (lib.min a b) * 100 + (lib.max a b) * 10 + plane;

  # One end of a link's /127, from its plane's /64.
  linkAddress =
    prefix: far: plane: ours:
    "${pool prefix plane}${linkPair far}:${if isLowerEnd far ours then "1" else "0"}";

  # One end's link-local. Link-local scope is per interface, so unlike the
  # globals these carry no pair and repeat across a router's links. They
  # still have to agree, and an adjacency forms on them alone: a global
  # address written backwards degrades, a link-local written backwards means
  # no adjacency at all.
  linkLla = far: ours: if isLowerEnd far ours then "fe80::1" else "fe80::2";

  # One end of a link's IPv4 /31, from circuitPrefix4: the two site indices
  # as decimal digits in the third octet, and the plane doubled plus the end
  # in the fourth, the lower-indexed site taking the odd address as it takes
  # :1 above. Decimal digits are what hold a site index below 10.
  linkAddress4 =
    far: plane: ours:
    let
      a = inventory.sites.${config.homelab.site}.index;
      b = inventory.sites.${far}.index;
      base = lib.removeSuffix "0.0/16" inventory.circuitPrefix4;
      end = if isLowerEnd far ours then 1 else 0;
    in
    "${base}${toString (lib.min a b * 10 + lib.max a b)}.${toString (2 * plane + end)}";

  # Our own IPv4 space as the firewalls test for it: the scheme's block and
  # the space the LANs still number from.
  site4 = "{ ${inventory.privatePrefix}, ${inventory.legacyPrefix} }";

  # This router's IPv4 loopback, which zebra takes as its router ID so the
  # LSP's TE router ID is an address of ours rather than whichever
  # interface address zebra would otherwise pick.
  routerId = inventory.loopbacks.${config.networking.hostName}.addr4 or null;

  # What an ip6gretap costs over its carrier: outer IPv6 40, the tunnel
  # encapsulation limit's destination-options header 8, GRE 4, inner
  # ethernet 14. Linux adds that destination-options header to IPv6 tunnels
  # by default -- `ip -d link` shows it as encaplimit -- and it is the part
  # nobody counts.
  #
  # Counted and then measured: on a 1420 carrier the largest frame the
  # kernel will send is 1354. It accepts a larger MTU than that and then
  # refuses to transmit at it, so an over-large value does not degrade, it
  # silently stops `isis hello padding` from ever forming an adjacency
  # while smaller traffic keeps working.
  gretapOverhead = 66;

  # frr_exporter's own default, and what the server's discovery hook uses.
  exporterPort = 9342;

  # The dial names, shared with the page module.
  names = import ./icl-names.nix;

  inherit (import ./reverse-zones.nix { inherit lib; }) nibbles6;

  hexDigit = lib.listToAttrs (
    lib.imap0 (i: c: lib.nameValuePair c i) (lib.stringToCharacters "0123456789abcdef")
  );

  # The /127 an address sits in, as its nibbles with the last bit cleared.
  # Every address on a link here is one end of a /127, and the derivation
  # writes them in a different form from a hand-allocated link, so they are
  # compared expanded and lowercased rather than as text.
  net127 =
    addr:
    let
      ns = nibbles6 (lib.toLower (lib.head (lib.splitString "/" addr)));
      last = hexDigit.${lib.last ns};
    in
    lib.concatStrings (lib.take 31 ns) + lib.toLower (lib.toHexString (last - lib.mod last 2));

  # One entry per /127 a link occupies: the endpoints it is built on, and the
  # circuit address if it carries one.
  linkNets =
    link:
    [ (net127 link.localAddress) ]
    ++ lib.optional (link.localCircuitAddress6 != null) (net127 link.localCircuitAddress6);
in
{
  # A loopback is a router's identity in the IGP and an anycast address is a
  # service's, and nothing else advertises either, so the module which runs
  # the IGP is the one which brings them in. Each is inert on a machine
  # which has none, as is the WireGuard exporter on one with no carrier.
  imports = [
    ./anycast.nix
    ./icl-page.nix
    ./isis-metrics.nix
    ./loopback.nix
    ./wireguard-exporter.nix
  ];

  options.homelab.interconnect = {
    privateKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        The WireGuard private key every carrier here uses, as a path a
        secret provider has already written. One key identifies this
        router, as it does for the dn42 tunnels, so pointing this at the
        same secret is reasonable; a separate one keeps the two blast
        radii apart.
      '';
    };

    # The IGP. Named for the implementation rather than the role, because
    # these options are its own: a different protocol would bring different
    # ones. Nothing outside this module names it -- dn42.nix speaks only of
    # "the IGP" -- so swapping implementations stays local to this file.
    isis = {
      enable = lib.mkEnableOption "IS-IS over the interconnect links, via FRR's isisd";

      net = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = if systemId == null then null else "${inventory.isis.area}.${systemId}.00";
        defaultText = lib.literalExpression "the inventory's area and this machine's system ID";
        example = "49.0001.0000.0000.0001.00";
        description = ''
          This router's NET: area address, system ID and selector. The
          system ID is six octets unique to this router within the routing
          domain, and is chosen rather than derived from any address; the
          inventory is its registry, keyed by machine name. The selector is
          always 00 for a router's own NET.

          Null when the inventory names no system ID for this machine,
          which the assertion below reports. Set it here for a machine
          which is not in that registry.
        '';
      };

      lspMtu = lib.mkOption {
        type = lib.types.int;
        default = 1300;
        description = ''
          Largest LSP this router originates. It must fit the smallest link
          in the area: FRR defaults to 1497, which an interconnect at 1354
          cannot carry, and the LSPs are then generated too large to flood.
          The assertion below checks it against every link here.
        '';
      };

      aggregate6 = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          A prefix this router originates into the IGP on behalf of its
          whole site, in CIDR notation, or null to originate none.

          A passive interface advertises every prefix on it and nothing
          finer: isisd has no per-prefix filter and no summary-address, so
          naming a LAN here would also hand the far site a dynamic delegated
          GUA. One aggregate says the same thing without that -- it never
          changes, and the more specifics on this side sort the traffic out
          when it arrives.

          Originated by redistributing the matching route out of zebra
          under a route-map. The route it matches is expected to be an
          unreachable aggregate covering the site, so a packet for an
          address nobody holds is rejected here rather than looping.
        '';
      };

      aggregate4 = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = ''
          The IPv4 prefixes this router originates on behalf of its whole
          site, on the same terms as aggregate6, or none. Several rather
          than one because the site's LANs number from a second block until
          they move under the first, and a far site needs a route to a
          source in either to answer it at all.
        '';
      };

      kernelDeny6 = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = ''
          IPv6 prefixes this router learns from the IGP but must not
          install, exactly as written. A second router at a site learns
          its own site's aggregates from the first, pointing over the
          circuit between them, while it reaches that site over its LAN;
          installed, they would carry its LAN traffic across the circuit
          sourced from the circuit address, which the site's policy drops
          as a far-site flow. zebra filters them before the kernel sees
          them; isisd still holds them.
        '';
      };

      kernelDeny4 = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "The same for IPv4 prefixes.";
      };

      passiveInterfaces = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = ''
          Interfaces this router advertises into the IGP without running
          the protocol on them: IS-IS puts their prefixes into our LSP but
          sends no hellos and forms no adjacency.

          This is what makes anything other than the circuits reachable
          from another site. A circuit advertises only the /127 it runs on,
          so the loopback and every site LAN stay invisible to the rest of
          the area until they are named here. Naming interfaces rather than
          prefixes keeps the inventory's secrets out of this config.

          Passive rather than a circuit because a LAN has no IS-IS
          neighbour to find: running the protocol there would send hellos
          to every host on the segment and accept an adjacency from
          anything that answered.
        '';
      };
    };

    links = lib.mkOption {
      default = { };
      description = ''
        Interconnect links to our other sites. The attribute name is a
        label and nothing derives from it: a site reached over two WANs has
        two links, so the far site alone no longer identifies one. site and
        plane do, and the interface names are built from them.
      '';
      type = lib.types.attrsOf (
        lib.types.submodule (
          { name, config, ... }:
          {
            options = {
              site = lib.mkOption {
                type = lib.types.str;
                default = name;
                defaultText = lib.literalExpression "the attribute name";
                description = ''
                  The site at the far end, naming its entry in the
                  inventory. Every per-link address derives from this
                  site's index and ours, so both ends compute the same
                  values without being told.
                '';
              };
              plane = lib.mkOption {
                type = lib.types.ints.between 0 9;
                default = 0;
                description = ''
                  Which of several parallel links to the same site this is.
                  Two links to one site are only redundant if they leave
                  over different WANs, which is what firewallMark arranges;
                  the plane is what keeps their addresses and interface
                  names apart.

                  It selects the /64 each link address comes from, so plane
                  0 is where a site's first link already lives and adding a
                  second renumbers nothing.
                '';
              };
              interface = lib.mkOption {
                type = lib.types.str;
                default = "icl-${config.site}${toString config.plane}";
                defaultText = lib.literalExpression ''"icl-''${site}''${plane}"'';
                description = ''
                  The GRETAP link; nftables matches the icl- prefix. The
                  trailing digit is the plane, as wan0 and wan1 carry
                  theirs.
                '';
              };
              carrier = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = "iclw-${config.site}${toString config.plane}";
                defaultText = lib.literalExpression ''"iclw-''${site}''${plane}"'';
                description = ''
                  The WireGuard carrier, which only ever carries the
                  GRETAP. Null for a link which needs none: two routers on
                  a trusted segment, or a lab link within one site. The
                  GRETAP is then built directly on localAddress and
                  remoteAddress, which must already be reachable.
                '';
              };
              publicKey = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                description = "The far site's WireGuard public key; null when there is no carrier.";
              };
              endpointFamily = lib.mkOption {
                type = lib.types.enum [
                  "ipv4"
                  "ipv6"
                ];
                default = "ipv6";
                description = ''
                  Which of the far site's dial names the derived endpoint
                  uses. The name pins the address family, which nothing else
                  can: a carrier steered out an uplink without IPv6 must
                  dial the ipv4 name, or it is steered correctly and then
                  finds no route.
                '';
              };
              endpoint = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default =
                  if config.carrier != null && isLowerEnd config.site true then
                    "${names.dial config.endpointFamily config.site}:${toString config.port}"
                  else
                    null;
                defaultText = lib.literalExpression "the far site's dial name and the link's port at the lower-indexed site, null at the other";
                description = ''
                  The far site's host:port, or null when it initiates to us.

                  The lower-indexed site dials: a link derives its endpoint
                  at that end and none at the other, so both ends agree
                  without being told and no link has two dialling ends or
                  none. A site whose addresses are dynamic cannot be
                  dialled, so it must be the lower end of every link it has,
                  which is what the house's index of 1 guarantees.
                '';
              };
              port = lib.mkOption {
                type = lib.types.nullOr lib.types.port;
                default = if config.carrier == null then null else linkPort config.site config.plane;
                defaultText = lib.literalExpression "51<a><b><plane> from the two site indices";
                description = ''
                  Our WireGuard listen port for this link, opened on the
                  WANs by nftables. Null when there is no carrier.

                  Derived like every other per-link value, from the two
                  sites' indices and the plane, so both ends reach the same
                  number and no two links can want one port. Site 01 to
                  site 02 is 51120 on plane 0 and 51121 on plane 1; site 02
                  to site 03 is 51230 and 51231.

                  Set it here only to hold a port a far end cannot change.
                '';
              };
              firewallMark = lib.mkOption {
                type = lib.types.nullOr lib.types.int;
                default = null;
                description = ''
                  A mark WireGuard sets on this carrier's outgoing packets,
                  for a routing policy rule that sends them out one WAN.
                  Null to leave the choice to the main routing table.

                  This is what makes two links to one site redundant rather
                  than merely duplicated: without it both carriers follow
                  the same default route, the IGP forms two adjacencies over
                  one path, and a WAN failure takes both at once. The rule
                  and the table it points at belong to the site, since only
                  it knows what its WANs are; this option is the half the
                  link owns.

                  The mark is on the outer packets, which is the only place
                  it could be -- what the GRETAP carries is already inside
                  WireGuard by then.
                '';
              };
              localAddress = lib.mkOption {
                type = lib.types.str;
                default = "${linkAddress inventory.carrierPrefix config.site config.plane true}/127";
                defaultText = lib.literalExpression "the link's /127 from carrierPrefix";
                description = ''
                  Our address with its prefix length, one end of a /127.
                  The GRETAP is built on these two addresses and nothing
                  else uses them.

                  With a carrier this module assigns it there. Without
                  one it does not: the address must already be configured
                  on whichever interface reaches the far end, because a
                  GRETAP's local address has to be a local address, not
                  merely a reachable one.
                '';
              };
              remoteAddress = lib.mkOption {
                type = lib.types.str;
                default = linkAddress inventory.carrierPrefix config.site config.plane false;
                defaultText = lib.literalExpression "the far end of the same /127";
                description = "The far site's carrier address, without a prefix length.";
              };
              localLla = lib.mkOption {
                type = lib.types.str;
                default = linkLla config.site true;
                defaultText = lib.literalExpression "fe80::1 at the lower-indexed site, fe80::2 at the other";
                description = ''
                  Our link-local on the interconnect. Both ends are ours, so
                  unlike a dn42 tunnel the two cannot share one mnemonic
                  address: they would collide.
                '';
              };
              lla = lib.mkOption {
                type = lib.types.str;
                default = linkLla config.site false;
                defaultText = lib.literalExpression "the other end of the same pair";
                description = "The far site's link-local on the interconnect.";
              };
              localCircuitAddress6 = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = "${linkAddress inventory.circuitPrefix6 config.site config.plane true}/127";
                defaultText = lib.literalExpression "the link's /127 from circuitPrefix6";
                description = ''
                  Our global address on the interconnect itself, with its
                  prefix length, one end of a /127 from the inventory's
                  circuitPrefix6. Null for a link which needs none.

                  This is what a router originating traffic toward the far
                  site uses as a source, because RFC 6724 prefers an address
                  on the outgoing interface before it considers any other
                  rule. Without one the choice falls to the longest matching
                  prefix among every address the machine holds, and a router
                  with no LAN can lose that to an address on an unrelated
                  interface -- a tailnet address, which no site rule matches
                  and which the far side cannot route a reply to.

                  Distinct from localAddress, which is the carrier's: routes
                  point at the interconnect, not at the tunnel carrying it.
                '';
              };
              localCircuitAddress4 = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = "${linkAddress4 config.site config.plane true}/31";
                defaultText = lib.literalExpression "the link's /31 from circuitPrefix4";
                description = ''
                  Our IPv4 address on the interconnect, with its prefix
                  length, one end of a /31 from the inventory's
                  circuitPrefix4, or null for a link carrying no IPv4. The
                  IGP needs an IPv4 next hop on a circuit to install any
                  IPv4 route across it.
                '';
              };
              carrierMtu = lib.mkOption {
                type = lib.types.int;
                default = 1420;
                description = "Carrier MTU: path MTU less WireGuard's 80.";
              };

              metric = lib.mkOption {
                type = lib.types.nullOr lib.types.int;
                default = null;
                description = ''
                  This circuit's IS-IS metric, or null for isisd's default
                  of 10.

                  Set it where two circuits are not comparable paths. A link
                  between two machines on one segment and a tunnel to
                  another region both default to 10, which makes every
                  address reachable over either equally good -- and an
                  address held at both sites is then load balanced between
                  them by a router that has no way to know one of the two
                  cannot answer.
                '';
              };
              mtu = lib.mkOption {
                type = lib.types.int;
                default = config.carrierMtu - gretapOverhead;
                defaultText = lib.literalExpression "carrierMtu - 66";
                description = ''
                  Link MTU, derived from the carrier's so the arithmetic is
                  in one place and visible: see gretapOverhead above for
                  what the 66 is made of and why counting it wrong is not a
                  performance problem but a dead adjacency.

                  This is the value the IGP has to be sized against, and
                  both ends must agree on it: isis hello padding makes every
                  hello full size, so a mismatch refuses the adjacency
                  rather than degrading it.

                  An IGP must be told rather than left on defaults sized
                  for 1500: FRR's isisd, for one, defaults lsp-mtu to
                  1497, which does not fit, and generates LSPs too large
                  to flood.
                '';
              };
            };
          }
        )
      );
    };
  };

  config = lib.mkIf (cfg.links != { }) {
    # wg show reads a carrier's handshake and transfer counters at the
    # shell, which is the fastest way to tell a carrier that is configured
    # from one that merely has carrier.
    environment.systemPackages = [ pkgs.wireguard-tools ];

    assertions = [
      {
        assertion =
          cfg.privateKeyFile != null || lib.all (link: link.carrier == null) (lib.attrValues cfg.links);
        message = "homelab.interconnect.privateKeyFile is needed by any link with a carrier";
      }
      {
        assertion = lib.all (link: link.carrier == null || (link.publicKey != null && link.port != null)) (
          lib.attrValues cfg.links
        );
        message = "an interconnect link with a carrier needs publicKey and port";
      }
      {
        assertion =
          let
            ports = lib.filter (p: p != null) (lib.mapAttrsToList (_: link: link.port) cfg.links);
          in
          lib.unique ports == ports;
        message = "interconnect links must use unique WireGuard listen ports";
      }
      {
        # Two links to one site on one plane derive identical addresses and
        # identical interface names, which is a collision the far end never
        # sees: it would come out as one circuit that will not settle.
        assertion =
          let
            planes = lib.mapAttrsToList (_: link: "${link.site}/${toString link.plane}") cfg.links;
          in
          lib.unique planes == planes;
        message = "interconnect links to one site must each use a different plane";
      }
      {
        # The assertion above catches two derived links colliding. This one
        # catches a link whose addresses were written by hand landing on a
        # derived link's, which nothing else would notice: the two would
        # answer for each other's /127 and the adjacency they broke would be
        # the one nobody was looking at.
        assertion =
          let
            nets = lib.concatMap linkNets (lib.attrValues cfg.links);
          in
          lib.unique nets == nets;
        message = "interconnect links must not share a carrier or circuit /127";
      }
      {
        assertion = lib.all (link: inventory.sites ? ${link.site}) (lib.attrValues cfg.links);
        message = "every interconnect link's site must be named in the inventory";
      }
      {
        assertion = !cfg.isis.enable || cfg.isis.net != null;
        message = "interconnect isis needs a system ID in the inventory, or isis.net set here";
      }
      {
        assertion =
          !cfg.isis.enable || lib.all (link: cfg.isis.lspMtu < link.mtu) (lib.attrValues cfg.links);
        message = "interconnect isis.lspMtu must be smaller than every link's mtu";
      }
      {
        # The IPv4 circuit address writes both site indices as decimal
        # digits in one octet; see linkAddress4.
        assertion = lib.all (
          link:
          link.localCircuitAddress4 == null
          || (inventory.sites.${config.homelab.site}.index < 10 && inventory.sites.${link.site}.index < 10)
        ) (lib.attrValues cfg.links);
        message = "an interconnect link with an IPv4 circuit address needs both site indices below 10";
      }
      {
        # The transit rules below reach a site through the NixOS firewall,
        # and only its nftables backend renders them: on iptables they are
        # silently inert. A site running a ruleset of its own writes them
        # itself.
        assertion =
          config.networking.nftables.ruleset != ""
          || (config.networking.firewall.enable && config.networking.nftables.enable);
        message = "interconnect needs the NixOS firewall on its nftables backend, or a full nftables ruleset of the site's own";
      }
    ];

    # The carriers' listen ports, for a site whose firewall is the NixOS
    # one. Derived from the links so the two cannot drift: a link without a
    # carrier has no port and opens nothing. Inert on a site running its own
    # nftables ruleset, which reads the same option to build its rules.
    networking.firewall.allowedUDPPorts = lib.filter (p: p != null) (
      lib.mapAttrsToList (_: link: link.port) cfg.links
    );

    # Paths here are asymmetric by construction: a flow arrives addressed to
    # an interface the route back to its source does not name, and the IGP
    # may move that route between circuits at any time. Strict reverse path
    # filtering drops such a flow; loose asks only that a route to the
    # source exists. A site running its own ruleset keeps the firewall off
    # and checks spoofed sources on its LAN ports, where the expected
    # interface is known.
    networking.firewall.checkReversePath = lib.mkDefault "loose";

    # Site traffic passing between circuits, on the same kind of site. Its
    # forward chain drops conntrack's invalid state before any rule of ours
    # runs, and a flow whose return takes another circuit or another site
    # is seen here in one direction only, which is what invalid means to
    # conntrack. So such traffic is not tracked: an untracked packet takes
    # the chain's untracked branch to the accept below. The destination
    # test keeps what is for this machine tracked and under the input
    # rules. A site running its own ruleset orders its accept above the
    # drop instead.
    networking.nftables.tables.icl-transit = lib.mkIf config.networking.firewall.enable {
      family = "inet";
      content = ''
        chain prerouting {
          type filter hook prerouting priority raw; policy accept;
          iifname "icl-*" ip6 saddr ${inventory.ulaPrefix} ip6 daddr ${inventory.ulaPrefix} fib daddr type != local notrack
          iifname "icl-*" ip saddr ${site4} ip daddr ${site4} fib daddr type != local notrack
        }
      '';
    };

    # What the discard route on lo (below, with the networks) discards,
    # counted on a site whose firewall is the NixOS one: a blackholed
    # packet is dropped at the routing decision and never reaches the
    # forward hook, so it is counted before routing, by asking the table
    # what it would do. A site running its own ruleset carries the same
    # rule and counter itself.
    networking.nftables.tables.discard = lib.mkIf config.networking.firewall.enable {
      family = "inet";
      content = ''
        counter blackhole_drop {}

        chain prerouting {
          type filter hook prerouting priority raw; policy accept;
          fib daddr type blackhole counter name blackhole_drop drop comment "blackholed destination"
        }
      '';
    };

    # IP traffic on each circuit by family and direction, as set element
    # counters the nftables exporter publishes (see nftables-exporter.nix):
    # a set per family and direction keyed by interface name, whose
    # elements are this site's circuits, matched by a rule with no verdict.
    # Counted on the wire, before the filter on the way in and after it on
    # the way out, so the figure is what the carrier carried rather than
    # what policy kept. The IGP's own PDUs are not IP and are not counted.
    # Its own table because a site running its own ruleset has one too,
    # and tables render beside a ruleset either way.
    networking.nftables.tables.icl-accounting = {
      family = "inet";
      content =
        let
          circuits = lib.concatMapStringsSep ", " (link: ''"${link.interface}"'') (
            lib.attrValues cfg.links
          );
          set = name: ''
            set ${name} {
              type ifname
              counter
              elements = { ${circuits} }
            }
          '';
        in
        ''
          ${set "icl_in_v4"}
          ${set "icl_in_v6"}
          ${set "icl_out_v4"}
          ${set "icl_out_v6"}
          chain prerouting {
            type filter hook prerouting priority filter; policy accept;
            meta nfproto ipv4 iifname @icl_in_v4
            meta nfproto ipv6 iifname @icl_in_v6
          }

          chain postrouting {
            type filter hook postrouting priority filter; policy accept;
            meta nfproto ipv4 oifname @icl_out_v4
            meta nfproto ipv6 oifname @icl_out_v6
          }
        '';
    };

    # Both ends of a transiting flow are ours, so the test is our own space
    # on each side. The wildcard admits a circuit to a new site without a
    # second place to remember.
    networking.firewall.extraForwardRules = lib.mkIf config.networking.firewall.enable ''
      iifname "icl-*" oifname "icl-*" ip6 saddr ${inventory.ulaPrefix} ip6 daddr ${inventory.ulaPrefix} counter accept comment "site transit between circuits"
      iifname "icl-*" oifname "icl-*" ip saddr ${site4} ip daddr ${site4} counter accept comment "site transit between circuits"
    '';

    # isisd alongside bird, not instead of it. The two carry disjoint
    # prefixes -- our own topology here, the dn42 table there -- so neither
    # daemon writes a route the other owns, which is what keeps them out of
    # each other's way in the kernel. The split is only real once dn42's
    # ibgpInternal is turned off; until then iBGP still carries our own
    # prefixes and this runs beside it for comparison.
    services.frr = lib.mkIf cfg.isis.enable {
      isisd.enable = true;
      # Rendered by sops at activation rather than written to the store,
      # since the IS-IS password is in it; see the template below.
      configFile = config.sops.templates."frr-isis.conf".path;
    };

    # One password for the area, from the shared secrets file every router
    # decrypts. Hellos carry it per circuit, so an adjacency forms only with
    # a router holding it, and level-2 LSPs and SNPs carry it for the
    # domain, so a router which does form one cannot feed the database
    # anything unsigned. The circuits between sites are inside WireGuard
    # already; the link between two routers on one segment is not, and this
    # is what stands in for that there.
    sops.secrets."isis/password" = lib.mkIf cfg.isis.enable {
      sopsFile = ../secrets/common.yaml;
    };

    # Named for what it holds rather than frr.conf: the server also renders
    # one of those, for the FRR lab container in its dev.nix.
    sops.templates."frr-isis.conf" = lib.mkIf cfg.isis.enable {
      owner = "frr";
      group = "frr";
      mode = "0440";
      restartUnits = [ "frr.service" ];
      content =
        let
          password = config.sops.placeholder."isis/password";
          # Only commands are emitted: a comment inside an interface block
          # would be at the mercy of how the parser treats it, and this
          # config cannot be checked before it reaches the router.
          #
          # point-to-point because two routers on a link have no DIS to
          # elect; padded hellos while an adjacency forms because a
          # disagreement about MTU is the failure this link is most likely
          # to have, and padding turns it into a refused adjacency rather
          # than silent partial flooding. Only while it forms: a hello a
          # second at full size is most of an idle carrier's traffic, and
          # the MTU was proved the moment the adjacency came up.
          #
          # A hello a second, three missed: a carrier gives no link-down
          # signal and the router cannot run BFD (bird holds its port), so
          # the hello timeout is the whole of failure detection here.
          circuit = link: ''
            interface ${link.interface}
             ip router isis ${tag}
             ipv6 router isis ${tag}
             isis circuit-type level-2-only
             isis network point-to-point
             isis hello padding during-adjacency-formation
             isis hello-interval 1
             isis hello-multiplier 3
             isis password md5 ${password}
            ${lib.optionalString (link.metric != null) " isis metric ${toString link.metric}\n"}!
          '';
          passive = name: ''
            interface ${name}
             ip router isis ${tag}
             ipv6 router isis ${tag}
             isis passive
            !
          '';
          # Redistribution is the only way to originate a prefix which is
          # not an address on an interface, and the route-map is what makes
          # it safe: "kernel" is every route zebra did not write itself,
          # which on a router also running bird is the whole dn42 table.
          # The match is the aggregate alone and the implicit deny carries
          # the rest.
          #
          # kernel rather than static because that is how zebra classifies
          # it: networkd installs the aggregate with proto static, and
          # zebra calls anything it did not install itself a kernel route.
          #
          # The level is not optional, and isisd rejects the whole line
          # without it -- logged as an unknown command, after which the
          # daemon carries on with no redistribution at all. level-2 to
          # match is-type above.
          aggregate6 = lib.optionalString (cfg.isis.aggregate6 != null) ''
            ipv6 prefix-list isis-aggregate6 seq 5 permit ${cfg.isis.aggregate6}
            !
            route-map isis-aggregate6 permit 10
             match ipv6 address prefix-list isis-aggregate6
            !
          '';
          aggregate4 = lib.optionalString (cfg.isis.aggregate4 != [ ]) ''
            ${lib.concatImapStrings (
              i: p: "ip prefix-list isis-aggregate4 seq ${toString (5 * i)} permit ${p}\n"
            ) cfg.isis.aggregate4}!
            route-map isis-aggregate4 permit 10
             match ip address prefix-list isis-aggregate4
            !
          '';
          # What zebra installs from the IGP: everything but the prefixes
          # named in kernelDeny, matched exactly by a prefix-list and
          # dropped by a route-map zebra applies to isisd's routes.
          kernelDeny =
            family: prefixes:
            let
              ip = if family == "ipv6" then "ipv6" else "ip";
            in
            lib.optionalString (prefixes != [ ]) ''
              ${lib.concatImapStrings (
                i: p: "${ip} prefix-list isis-kernel-deny-${family} seq ${toString (5 * i)} permit ${p}\n"
              ) prefixes}!
              route-map isis-kernel-${family} deny 10
               match ${ip} address prefix-list isis-kernel-deny-${family}
              !
              route-map isis-kernel-${family} permit 20
              !
              ${ip} protocol isis route-map isis-kernel-${family}
              !
            '';
          redistribute =
            lib.optionalString (
              cfg.isis.aggregate6 != null
            ) " redistribute ipv6 kernel level-2 route-map isis-aggregate6\n"
            + lib.optionalString (
              cfg.isis.aggregate4 != [ ]
            ) " redistribute ipv4 kernel level-2 route-map isis-aggregate4\n";

          # isisd logs every route zebra offers it for redistribution, at
          # debug and gated by nothing, so with an aggregate configured the
          # whole dn42 table's churn lands in the journal -- some 90 lines a
          # minute, swamping anything worth reading there. FRR logs at debug
          # when nothing tells it otherwise, so tell it.
          logging = "log syslog informational";
        in
        # The first lines are what the FRR module writes around
        # services.frr.config, which configFile replaces wholesale.
        #
        # isisd schedules SPF on every LSP update with a new sequence
        # number, content compared or not, so the LSP refreshes of routers
        # restarted by one deploy arrive as a burst every quarter hour, a
        # run per refresh. The RFC 8405 delay, at that RFC's suggested
        # values, does not merge those: the refreshes land minutes apart
        # and its windows are sub-second. It backs off under sustained
        # churn, and a lone change still computes within its initial delay.
        #
        # The overload bit for a while after isisd starts, which every
        # deploy does: a router which has just formed its adjacencies
        # attracts transit before its database and routes have settled,
        # and on a ring every edge is a transit node. With the bit set the
        # others still reach what this router advertises itself and route
        # around it for everything else, until it clears.
        ''
          hostname ${config.networking.hostName}
          service integrated-vtysh-config
          ${logging}
          ${lib.optionalString (routerId != null) "ip router-id ${routerId}"}
          !
          ${aggregate6}${aggregate4}${kernelDeny "ipv6" cfg.isis.kernelDeny6}${kernelDeny "ipv4" cfg.isis.kernelDeny4}router isis ${tag}
           is-type level-2-only
           net ${cfg.isis.net}
           lsp-mtu ${toString cfg.isis.lspMtu}
           log-adjacency-changes
           spf-delay-ietf init-delay 50 short-delay 200 long-delay 5000 holddown 10000 time-to-learn 500
           set-overload-bit on-startup 60
           domain-password md5 ${password} authenticate snp validate
          ${redistribute}!
          ${lib.concatMapStrings circuit (lib.attrValues cfg.links)}
          ${lib.concatMapStrings passive cfg.isis.passiveInterfaces}
        '';
    };

    # Restart rather than reload when the configuration changes. nixpkgs
    # sets reloadIfChanged for this unit, so a changed frr.conf becomes
    # `systemctl reload`, which runs frr-reload.py to diff the running
    # configuration against the new one through vtysh. On a router with
    # anything beyond a trivial configuration that hangs against mgmtd's
    # datastore lock until systemd times the job out at TimeoutSec, kills
    # all five daemons with SIGKILL, and restarts them anyway: two minutes
    # per deploy and an unclean shutdown, with no LSP purge. Starting from
    # cold takes a second or two, so the reload buys nothing it does not
    # then lose.
    systemd.services.frr.reloadIfChanged = lib.mkIf cfg.isis.enable (lib.mkForce false);

    # vtysh reaches the daemons over sockets owned by frr:frrvty, so the
    # admin joins that group and runs it as themselves. common.nix caches no
    # sudo credentials, and reading an adjacency is several commands, so the
    # alternative is a YubiKey touch each.
    users.users.${config.homelab.user}.extraGroups = lib.mkIf cfg.isis.enable [ "frrvty" ];

    # There is no IS-IS exporter. tynany's frr_exporter is the only one
    # packaged, and it collects BGP, OSPF, BFD, PIM and VRRP -- the binary
    # does not contain the string "isis". Adjacency state is therefore not
    # available as a metric at all, and what stands in for it comes from
    # zebra rather than from isisd:
    #
    #   route, with --collector.route.detailed-routes, breaks the RIB down
    #   by protocol. That flag is off by default and is the whole reason to
    #   run this collector: without it there is only a total, and
    #   frr_route_rib_count{route_type="isis"} is the proxy for the
    #   adjacency, since losing the circuit takes its routes with it.
    #
    #   status reports only whether zebra answers `show version` -- not the
    #   state of each daemon. isisd can be dead with frr_status_up still 1,
    #   so it is a liveness check for FRR itself and nothing more.
    #
    # bfd, bgp and ospf are on by default and would each query a daemon this
    # router does not run; disabling them is what keeps the scrape from
    # erroring rather than merely reporting nothing.
    #
    # Scraped by the server's exporter discovery, which has a hook for this
    # option -- there is no services.prometheus.exporters.frr to be found.
    systemd.services.frr-exporter = lib.mkIf cfg.isis.enable {
      description = "Prometheus FRR exporter";
      wantedBy = [ "multi-user.target" ];
      after = [ "frr.service" ];
      wants = [ "frr.service" ];
      serviceConfig = {
        ExecStart = utils.escapeSystemdExecArgs [
          "${pkgs.prometheus-frr-exporter}/bin/frr_exporter"
          "--web.listen-address=:${toString exporterPort}"
          # Each daemon's own socket rather than vtysh, which the exporter
          # itself recommends and which needs no sudo.
          "--frr.socket.dir-path=/run/frr"
          "--collector.route.detailed-routes"
          "--no-collector.bfd"
          "--no-collector.bgp"
          "--no-collector.ospf"
        ];
        Restart = "always";

        # frrvty is the group FRR creates for reading those sockets; a
        # DynamicUser outside it gets permission denied on every scrape.
        DynamicUser = true;
        SupplementaryGroups = [ "frrvty" ];
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        ProtectKernelTunables = true;
        ProtectControlGroups = true;
        RestrictNamespaces = true;
      };
    };

    systemd.network = {
      netdevs = lib.concatMapAttrs (
        _: link:
        lib.optionalAttrs (link.carrier != null) {
          "45-${link.carrier}" = {
            netdevConfig = {
              Name = link.carrier;
              Kind = "wireguard";
              MTUBytes = link.carrierMtu;
            };
            wireguardConfig = {
              PrivateKeyFile = cfg.privateKeyFile;
              ListenPort = link.port;
            }
            // lib.optionalAttrs (link.firewallMark != null) {
              FirewallMark = link.firewallMark;
            };
            wireguardPeers = [
              (
                {
                  PublicKey = link.publicKey;
                  # The far end of the carrier alone: the GRETAP's outer
                  # packets and nothing else may cross.
                  AllowedIPs = [ "${link.remoteAddress}/128" ];
                }
                // lib.optionalAttrs (link.endpoint != null) { Endpoint = link.endpoint; }
              )
            ];
          };
        }
        // {
          "45-${link.interface}" = {
            netdevConfig = {
              Name = link.interface;
              Kind = "ip6gretap";
              MTUBytes = link.mtu;
            };
            tunnelConfig = {
              Local = lib.head (lib.splitString "/" link.localAddress);
              Remote = link.remoteAddress;
              Independent = true;
            };
          };
        }
      ) cfg.links;

      networks = {
        # The discard prefix (RFC 6666) as a blackhole on every IGP node. A
        # route whose next hop is drawn from it is discarded wherever this
        # is held, so a prefix can be null-routed everywhere by announcing
        # it with such a next hop rather than by touching each router, and
        # a resolver answer pointing into it dies quietly at the first hop.
        # Counted by the discard table above.
        "5-lo" = {
          matchConfig.Name = "lo";
          routes = [
            {
              Destination = "100::/64";
              Type = "blackhole";
            }
          ];
        };
      }
      // lib.concatMapAttrs (
        _: link:
        lib.optionalAttrs (link.carrier != null) {
          "45-${link.carrier}" = {
            matchConfig.Name = link.carrier;
            # Deprecated, not merely unrouted: this address exists so the
            # GRETAP has an endpoint, and nothing should ever pick it as a
            # source. It is inside the site ULA, so without this a host at
            # a site whose loopback is also in that /48 chooses between the
            # two by longest common prefix, which is a tie. RFC 6724 avoids
            # a deprecated address long before it reaches that rule, and
            # the GRETAP's own packets are unaffected: their addresses are
            # configured on the netdev, not chosen.
            addresses = [
              {
                Address = link.localAddress;
                PreferredLifetime = "0";
              }
            ];
            networkConfig = {
              LinkLocalAddressing = "no";
              IPv6AcceptRA = false;
            };
          };
        }
        // {
          "45-${link.interface}" = {
            matchConfig.Name = link.interface;
            # A static link-local, as a dn42 tunnel has: both ends are ours,
            # so neither can be left to an address derived from a MAC the far
            # side would have to be told about.
            address = [
              "${link.localLla}/64"
            ]
            ++ lib.optional (link.localCircuitAddress6 != null) link.localCircuitAddress6
            ++ lib.optional (link.localCircuitAddress4 != null) link.localCircuitAddress4;
            networkConfig = {
              LinkLocalAddressing = "no";
              IPv6AcceptRA = false;
            };
          };
        }
      ) cfg.links;
    };
  };
}
