{
  config,
  lib,
  ...
}:

# Links between our own sites: the link itself, not what runs on it.
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
in
{
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
        type = lib.types.str;
        example = "49.0001.0000.0000.0001.00";
        description = ''
          This router's NET: area address, system ID and selector. The
          system ID is six octets unique to this router within the routing
          domain, and is chosen rather than derived from any address.
        '';
      };

      area = lib.mkOption {
        type = lib.types.str;
        default = "core";
        description = "The isisd process tag, which names the area in its config.";
      };

      lspMtu = lib.mkOption {
        type = lib.types.int;
        default = 1300;
        description = ''
          Largest LSP this router originates. It must fit the smallest link
          in the area: FRR defaults to 1497, which an interconnect at 1382
          cannot carry, and the LSPs are then generated too large to flood.
          The assertion below checks it against every link here.
        '';
      };

      passiveInterfaces = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = ''
          Interfaces whose prefixes are advertised into the IGP without
          forming an adjacency -- the site LANs, so the ULA and the v4
          prefixes reach the other site. Naming interfaces rather than
          prefixes keeps the inventory's secrets out of this config.
        '';
      };
    };

    links = lib.mkOption {
      default = { };
      description = "Interconnect links to our other sites, keyed by the far site's name.";
      type = lib.types.attrsOf (
        lib.types.submodule (
          { name, ... }:
          {
            options = {
              interface = lib.mkOption {
                type = lib.types.str;
                default = "icl-${name}";
                defaultText = lib.literalExpression ''"icl-''${name}"'';
                description = "The GRETAP link; nftables matches the icl- prefix.";
              };
              carrier = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = "iclw-${name}";
                defaultText = lib.literalExpression ''"iclw-''${name}"'';
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
              endpoint = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                description = "The far site's host:port, or null when it always initiates to us.";
              };
              port = lib.mkOption {
                type = lib.types.nullOr lib.types.port;
                default = null;
                description = ''
                  Our WireGuard listen port for this link, opened on the
                  WANs by nftables. Null when there is no carrier.
                '';
              };
              localAddress = lib.mkOption {
                type = lib.types.str;
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
                description = "The far site's carrier address, without a prefix length.";
              };
              localLla = lib.mkOption {
                type = lib.types.str;
                description = ''
                  Our link-local on the interconnect. Both ends are ours, so
                  unlike a dn42 tunnel the two cannot share one mnemonic
                  address: they would collide.
                '';
              };
              lla = lib.mkOption {
                type = lib.types.str;
                description = "The far site's link-local on the interconnect.";
              };
              carrierMtu = lib.mkOption {
                type = lib.types.int;
                default = 1420;
                description = "Carrier MTU: path MTU less WireGuard's 80.";
              };
              mtu = lib.mkOption {
                type = lib.types.int;
                default = 1382;
                description = ''
                  Link MTU: the carrier's 1420 less GRETAP's 38 (outer
                  IPv4 20, GRE 4, inner ethernet 14). Flat rather than
                  derived, so a carrier-less link runs the same number it
                  would across sites -- a lab link at 1462 would exercise
                  an MTU that never exists in production, and this is the
                  value the IGP has to be sized against.

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
    assertions = [
      {
        assertion =
          cfg.privateKeyFile != null
          || lib.all (link: link.carrier == null) (lib.attrValues cfg.links);
        message = "homelab.interconnect.privateKeyFile is needed by any link with a carrier";
      }
      {
        assertion = lib.all (
          link: link.carrier == null || (link.publicKey != null && link.port != null)
        ) (lib.attrValues cfg.links);
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
        assertion =
          !cfg.isis.enable
          || lib.all (link: cfg.isis.lspMtu < link.mtu) (lib.attrValues cfg.links);
        message = "interconnect isis.lspMtu must be smaller than every link's mtu";
      }
    ];

    # isisd alongside bird, not instead of it. The two carry disjoint
    # prefixes -- our own topology here, the dn42 table there -- so neither
    # daemon writes a route the other owns, which is what keeps them out of
    # each other's way in the kernel. The split is only real once dn42's
    # ibgpInternal is turned off; until then iBGP still carries our own
    # prefixes and this runs beside it for comparison.
    services.frr = lib.mkIf cfg.isis.enable {
      isisd.enable = true;
      config =
        let
          tag = cfg.isis.area;
          # Only commands are emitted: a comment inside an interface block
          # would be at the mercy of how the parser treats it, and this
          # config cannot be checked before it reaches the router.
          #
          # point-to-point because two routers on a link have no DIS to
          # elect; padded hellos because a disagreement about MTU is the
          # failure this link is most likely to have, and padding turns it
          # into a refused adjacency rather than silent partial flooding.
          circuit = name: ''
            interface ${name}
             ip router isis ${tag}
             ipv6 router isis ${tag}
             isis circuit-type level-2-only
             isis network point-to-point
             isis hello padding
            !
          '';
          passive = name: ''
            interface ${name}
             ip router isis ${tag}
             ipv6 router isis ${tag}
             isis passive
            !
          '';
        in
        ''
          router isis ${tag}
           is-type level-2-only
           net ${cfg.isis.net}
           lsp-mtu ${toString cfg.isis.lspMtu}
          !
          ${lib.concatMapStrings circuit (lib.mapAttrsToList (_: link: link.interface) cfg.links)}
          ${lib.concatMapStrings passive cfg.isis.passiveInterfaces}
        '';
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

      networks = lib.concatMapAttrs (
        _: link:
        lib.optionalAttrs (link.carrier != null) {
          "45-${link.carrier}" = {
            matchConfig.Name = link.carrier;
            address = [ link.localAddress ];
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
          address = [ "${link.localLla}/64" ];
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
