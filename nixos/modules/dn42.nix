{
  config,
  lib,
  pkgs,
  utils,
  ...
}:

# dn42 (https://dn42.dev) peering: WireGuard tunnels to peers, BIRD 2 for
# MP-BGP with ROA validation, and origination of our registered prefixes.
#
# The router owns the dn42 presence: tunnels terminate on the WAN's static
# IPv4 address and the daemon announces our aggregates. The firewall side
# lives in nftables.nix, keyed off the homelab.dn42 options declared here.
#
# dn42 interfaces come in two classes, and the prefix is the trust boundary:
#
#   dn42e-<peer>  external. A WireGuard tunnel to somebody else's network.
#                 Only BGP, BFD and ICMP are accepted from it.
#   dn42i-<name>  internal. A VLAN carrying our own dn42-addressed hosts.
#                 Same policy today, but it is the side that may later be
#                 offered router services such as DNS.
#
# nftables and bird both match on those prefixes, so a new interface picks
# up its class's policy from its name. Keeping one `dn42-*` wildcard for
# both would silently merge the classes, since it matches either prefix.
#
# Addressing. We announce the two aggregates and nothing else: dn42 asks
# networks not to deaggregate, and lengths inside our own AS are
# unconstrained, so per-site prefixes ride an IGP rather than the global
# table. IPv4 is 16 addresses which can never grow, so it is a pool of
# routed /32s rather than a subnet, and only a host serving dn42 takes one.
#
# IPv6 has room for structure: the fourth hextet reads as decimal SSVV,
# site then VLAN, the way the site ULA writes its VLAN id; both are two
# decimal digits, so ids stay under 100 or they collide. Site 00 is the
# network itself rather than a place -- :0000::/64 loopbacks, :0001::/64
# anycast, which every site can answer for because only the /48 above it
# is ever announced. Sites begin at :0100::/56, 256 /64s each.
#
# A second site, when there is one. Both routers originate both aggregates
# and nothing more specific: dn42 delivers to whichever is nearer, our own
# routing carries the rest, and an anycast address in site 00 is answerable
# at either. The registry needs no change for this -- max-length stays at
# the prefix length, and per-site prefixes never leave the AS. The cost is
# that while the link between sites is down, traffic entering at the wrong
# one hits the unreachable aggregate; the answer is a second path between
# sites, not a more specific announcement.
#
# That link would be a third interface class: trusted like dn42i- but a
# tunnel, and the only one which imports -- dn42_import rejects our own
# space by design (is_self_net), so it needs a filter of its own.

let
  cfg = config.homelab.dn42;
  inventory = config.homelab.inventory;

  # bird protocol names allow underscores but not dashes.
  birdName = name: lib.replaceStrings [ "-" ] [ "_" ] name;

  # Prometheus exporter for the round trip to each peer across its tunnel,
  # built from source in this repository like nftables_exporter. It sends
  # ICMPv6 echo requests over a raw socket bound to each tunnel interface,
  # which is what reaching a link-local address takes: the unprivileged ICMP
  # datagram socket cannot carry the scope a link-local send requires. The
  # server scrapes it on port 9631, next to nftables_exporter's wiki
  # allocation; see nixos/servnerr-4/prometheus.nix.
  # Go 1.27 from unstable, matching the toolchain used everywhere else.
  dn42_peer_exporter = (pkgs.buildGoModule.override { go = pkgs.unstable.go_1_27; }) {
    pname = "dn42_peer_exporter";
    version = "0.1.0";
    src = ../../go/internal/dn42_peer_exporter;
    vendorHash = "sha256-Bs0fCNaL5WqI/87XjKYNgI1bjZFyv5/croD4zq1PPe0=";
  };

  # One WireGuard interface per peer: WireGuard routes internally by peer
  # public key, so multiple BGP peers cannot share an interface. All tunnels
  # share one private key, each with its own listen port.
  peerNetdevs = lib.mapAttrs' (
    _: peer:
    lib.nameValuePair "50-${peer.interface}" {
      netdevConfig = {
        Name = peer.interface;
        Kind = "wireguard";
        MTUBytes = peer.mtu;
      };
      wireguardConfig = {
        PrivateKeyFile = config.sops.secrets."dn42/wireguard_key".path;
        ListenPort = peer.port;
      };
      wireguardPeers = [
        (
          {
            PublicKey = peer.publicKey;
            # BGP decides what is routed; networkd installs no routes for
            # AllowedIPs, so accept anything within the tunnel.
            AllowedIPs = [
              "0.0.0.0/0"
              "::/0"
            ];
          }
          // lib.optionalAttrs (peer.endpoint != null) { Endpoint = peer.endpoint; }
        )
      ];
    }
  ) cfg.peers;

  peerNetworks = lib.mapAttrs' (
    _: peer:
    lib.nameValuePair "50-${peer.interface}" {
      matchConfig.Name = peer.interface;
      # Sessions run over static link-local addresses; see the lla option
      # for the choice of ours.
      address = [ "${cfg.lla}/64" ];
      networkConfig = {
        LinkLocalAddressing = "no";
        IPv6AcceptRA = false;
        # dn42 routing is asymmetric and the tunnels carry IPv4 with IPv6
        # next hops, so the kernel's default loose rp_filter (from systemd's
        # 50-default.conf sysctls) would drop replies arriving over a
        # different peer than the one the FIB prefers. The wiki says to
        # disable it (https://dn42.dev/howto/wireguard); doing so per tunnel
        # leaves the LANs' spoof check in nftables.nix untouched.
        IPv4ReversePathFilter = "no";
      };
    }
  ) cfg.peers;

  # iBGP with our other sites, over the interconnect circuits named by the
  # ibgp option. next hop self is what makes those routes usable here: the
  # next hops the far site learned are on its own tunnels, which we have no
  # route to. Once an IGP carries the infrastructure this becomes a next
  # hop resolved through it instead.
  ibgpProtocols = lib.concatMapStrings (
    name:
    let
      link = config.homelab.interconnect.links.${name};
    in
    ''
      protocol bgp ${birdName link.interface} {
        local ${link.localLla} as OWNAS;
        neighbor ${link.lla} % '${link.interface}' as OWNAS;
        direct;

        ipv4 {
          extended next hop on;
          next hop self;
          import filter dn42_ibgp_import;
          export filter dn42_ibgp_export;
          import limit 9000 action block;
          import keep filtered on;
        };

        ipv6 {
          next hop self;
          import filter dn42_ibgp_import_v6;
          export filter dn42_ibgp_export_v6;
          import limit 9000 action block;
          import keep filtered on;
        };
      }
    ''
  ) cfg.ibgp;

  # One MP-BGP session per peer over IPv6 link-local, IPv4 carried with
  # extended next hop. BFD is opt-in per peer.
  peerProtocols = lib.concatStrings (
    lib.mapAttrsToList (_: peer: ''
      protocol bgp ${birdName peer.interface} from dnpeers {
        neighbor ${peer.lla} % '${peer.interface}' as ${toString peer.asn};
        ${lib.optionalString peer.bfd "bfd on;"}
      }
    '') cfg.peers
  );

  # The internal dn42 VLAN and the session it carries. Unlike a peer this
  # needs no tunnel: it is a tagged VLAN on the trunk, listed in the parent
  # interface's vlan set in networking.nix.
  #
  # All of its addressing is dn42 registry space, which is public data (see
  # the options above), so unlike the site LANs nothing here is an inventory
  # secret and the whole protocol block can live in the Nix store.
  # A nested indented string dedents to column 0, so every line after the
  # first needs the enclosing block's indentation added back; the
  # interpolation site supplies the first line's.
  indentTail =
    pad: text:
    lib.concatStringsSep "\n" (
      lib.imap0 (i: line: if i == 0 || line == "" then line else "${pad}${line}") (
        lib.splitString "\n" (lib.removeSuffix "\n" text)
      )
    );

  vlanChannels =
    vlan:
    lib.optionalString vlan.families.ipv6 ''
      ipv6 {
        import filter dn42i_import_v6;
        export filter dn42_export_v6;
        import limit 100 action block;
        import keep filtered on;
      };
    ''
    + lib.optionalString vlan.families.ipv4 ''
      ipv4 {
        # As with the dn42 peers: IPv4 NLRI over the one IPv6 session.
        extended next hop on;
        # The VLAN carries no IPv4 address, so if the speaker declines
        # extended next hop bird has none to fall back on; name our own.
        next hop address ${cfg.addr4};
        import filter dn42i_import;
        export filter dn42_export;
        import limit 100 action block;
        import keep filtered on;
      };
    '';

  # One BGP protocol per VLAN which asked for a session.
  vlanProtocols = lib.concatStrings (
    lib.mapAttrsToList (
      _: vlan:
      lib.optionalString vlan.session ''
        protocol bgp ${birdName vlan.interface} {
          local ${vlan.addr6} as OWNAS;
          neighbor ${vlan.neighbor} as ${toString vlan.asn};

          # eBGP with a private ASN, not iBGP: the speaker is its own AS with
          # no IGP, and an AS_PATH bearing OWNAS is a second, protocol level
          # reason a route we exported cannot come back in. An internal peer
          # would instead be able to originate into dn42 with nothing in the
          # path saying where the route came from.
          #
          # Passive: the speaker comes and goes with an experiment, so the
          # router waits to be connected to rather than retrying into a closed
          # port and logging every attempt.
          passive on;
          ${lib.optionalString vlan.bfd "bfd on;"}
          # Lab session only; the dn42e_ peers stay quiet. states and events
          # are a handful of lines per session change, cheap to leave on.
          # packets is deliberately left out: it logs every UPDATE, roughly
          # 6000 lines an hour of dn42 churn.
          ${lib.optionalString vlan.debug "debug { states, events };"}

          ${indentTail "  " (vlanChannels vlan)}
        }
      ''
    ) cfg.vlans
  );

in
{
  # The dn42 CA is trusted here, as on every machine with a dn42 interface.
  imports = [
    ./dn42-ca.nix
    # iBGP rides a site interconnect; the circuit itself is not ours.
    ./interconnect.nix
  ];

  options.homelab.dn42 = {
    # Registered dn42 resources, maintained by MDLAYHER-MNT in the dn42
    # registry. These are public registry data, not secrets.
    asn = lib.mkOption {
      type = lib.types.int;
      default = 4242423610;
      description = "Our dn42 autonomous system number.";
    };
    net4 = lib.mkOption {
      type = lib.types.str;
      default = "172.20.140.80/28";
      description = "Our registered dn42 IPv4 allocation.";
    };
    net6 = lib.mkOption {
      type = lib.types.str;
      default = "fde4:d0ad:ee0f::/48";
      description = "Our registered dn42 IPv6 allocation.";
    };
    addr4 = lib.mkOption {
      type = lib.types.str;
      default = "172.20.140.81";
      description = "The router's dn42 IPv4 address; also the ns1 glue.";
    };
    addr6 = lib.mkOption {
      type = lib.types.str;
      default = "fde4:d0ad:ee0f::1";
      description = "The router's dn42 IPv6 address; also the ns1 glue.";
    };
    domain = lib.mkOption {
      type = lib.types.str;
      default = "mdlayher.dn42";
      description = ''
        Our registered dn42 domain, delegated with the reverse space of
        net4 and net6 to ns1 beneath it, glue addr4 and addr6; served by
        coredns.nix. The apex resolves to the router, i.e. the peering page.
      '';
    };
    publicKey = lib.mkOption {
      type = lib.types.str;
      default = "yHaVotqyBwnDqT9mj4t28fFnpLyAGosU3gOq/ngmkHk=";
      description = ''
        Our WireGuard public key, shared by every tunnel. The private half
        is the secret dn42/wireguard_key in this host's secrets.yaml,
        generated once with wg genkey; the public half is what we hand to
        peers, so it is recorded here rather than recovered by decrypting
        the private key. The peering page (azo-page.nix) publishes it from
        here.
      '';
    };
    lla = lib.mkOption {
      type = lib.types.str;
      default = "fe80::3610";
      description = ''
        Our link-local address on every dn42 tunnel. The wiki only
        requires that each side pick a distinct fe80:: address
        (https://dn42.dev/howto/wireguard); using the last four digits of
        our AS4242423610 is a mnemonic many dn42 networks follow, not a
        rule.
      '';
    };
    secretsFile = lib.mkOption {
      type = lib.types.path;
      description = ''
        The sops file holding this site's dn42/wireguard_key. Each site
        has its own key, so the module cannot name the file: a path
        relative to the module would resolve under nixos/modules, and a
        secret declared with no sopsFile falls back to the host's
        sops.defaultSopsFile, which not every host sets.
      '';
    };
    peers = lib.mkOption {
      default = { };
      description = ''
        dn42 peers, keyed by the name shown on the peering page and in
        the peer exporter's metrics, and by default the interface name
        dn42e-<name> (see the interface option). All tunnels share the
        WireGuard private key secret dn42/wireguard_key in this host's
        secrets.yaml.
      '';
      type = lib.types.attrsOf (
        lib.types.submodule (
          { name, ... }:
          {
            options = {
              interface = lib.mkOption {
                type = lib.types.str;
                default = "dn42e-${name}";
                defaultText = lib.literalExpression ''"dn42e-''${name}"'';
                description = ''
                  The tunnel's interface name, and after dash-to-underscore
                  the bird protocol name. Override when the peer's name will
                  not fit: an ifname is at most 15 characters, and the
                  dn42e- prefix is what nftables and bird match on.
                '';
              };
              asn = lib.mkOption {
                type = lib.types.int;
                description = "The peer's autonomous system number.";
              };
              publicKey = lib.mkOption {
                type = lib.types.str;
                description = "The peer's WireGuard public key.";
              };
              endpoint = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                description = ''
                  The peer's WireGuard host:port endpoint, or null when the
                  peer always initiates to us instead.
                '';
              };
              port = lib.mkOption {
                type = lib.types.port;
                description = ''
                  Our WireGuard listen port for this peer, opened on the WANs
                  by nftables.nix. The common dn42 convention is 2xxxx where
                  xxxx is the last four digits of the peer's ASN, e.g.
                  AS4242420253 listens on 20253; see
                  https://dn42.burble.com/network/peering/ for an example of
                  a network documenting it. Pick something else on a last-
                  four-digits collision (the assertion below will object).
                '';
              };
              lla = lib.mkOption {
                type = lib.types.str;
                description = "The peer's link-local address on the tunnel.";
              };
              bfd = lib.mkOption {
                type = lib.types.bool;
                default = false;
                description = "Run BFD with this peer.";
              };
              mtu = lib.mkOption {
                type = lib.types.int;
                default = 1420;
                description = ''
                  Tunnel MTU. The wiki's guidance is path MTU minus 80 for
                  WireGuard overhead (https://dn42.dev/howto/wireguard);
                  1420 assumes a clean 1500 path and matches what most dn42
                  peers run. Lower it per peer when path MTU discovery says
                  so.
                '';
              };
            };
          }
        )
      );
    };

    ibgp = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Interconnect links (see homelab.interconnect.links) to run iBGP
        over: the same AS at both ends, carrying the dn42 table so each
        site reaches the other's peers. Our own topology travels by the
        IGP on the same circuit, and the site ULA never enters bird at all.
      '';
    };

    ibgpInternal = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether the iBGP sessions carry our own prefixes as well as the
        dn42 table. True until the IGP carries our topology: before that
        nothing else would, and the far site's hosts are unreachable.
        False after, or both would install the same routes from two
        daemons and the kernel would pick by metric rather than by design.
        This is the cutover switch, and flipping it is the cutover.
      '';
    };

    # Internal dn42 VLANs: our own links carrying dn42-addressed hosts,
    # keyed by name as peers are, and named dn42i-<name> so each inherits
    # the internal class's firewall and bird policy from its interface.
    # A second site declares its own; nothing here is specific to one.
    vlans = lib.mkOption {
      default = { };
      description = ''
        The internal dn42 VLANs this router carries. Each may also run a
        BGP session with a speaker on the link: the router exports the
        dn42 tables over it, so an implementation under development sees
        the real routing table rather than synthetic prefixes, and imports
        nothing back.
      '';
      type = lib.types.attrsOf (
        lib.types.submodule (
          { name, ... }:
          {
            options = {
              interface = lib.mkOption {
                type = lib.types.str;
                default = "dn42i-${name}";
                defaultText = lib.literalExpression ''"dn42i-''${name}"'';
                description = ''
                  The VLAN's interface name, and after dash-to-underscore
                  the bird protocol name. The dn42i- prefix is what
                  nftables and bird match on.
                '';
              };
              onLink4 = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                description = ''
                  The part of our IPv4 allocation on-link here, routed to
                  this VLAN so the router can ARP for its hosts without
                  being told which exist. Null on a VLAN carrying no dn42
                  IPv4 hosts. No site owns a share of the allocation: it
                  is one flat pool of /32s (see the header above), and
                  this range is only sized to cover what is assigned here.
                '';
              };
              session = lib.mkEnableOption ''
                a BGP session with a speaker on this VLAN. Its neighbor,
                asn and families below describe that session; without it
                the VLAN carries hosts and nothing else
              '';
              vlan = lib.mkOption {
                type = lib.types.int;
                description = ''
                  VLAN id, tagged on the same trunk as the site LANs; the parent
                  interface lists it in networking.nix. 42 is a mnemonic, well
                  clear of the site VLAN ids.
                '';
              };
              net6 = lib.mkOption {
                type = lib.types.str;
                description = ''
                  The /64 carried on the VLAN, from our registered allocation:
                  site 01, VLAN 42, under the addressing scheme at the top of this
                  file. None of site 00's, which hold the loopbacks and the
                  anycast block and are reachable from every site.
                '';
              };
              addr6 = lib.mkOption {
                type = lib.types.str;
                description = "The router's address on the VLAN, and the BGP local address.";
              };
              neighbor = lib.mkOption {
                type = lib.types.str;
                description = ''
                  The speaker's address on the VLAN, and the only BGP neighbor the
                  router accepts there. Chosen rather than learned: the container
                  forms it from the advertised prefix with a fixed interface
                  identifier (networkd Token=static:::10, the same one it uses on
                  dev0), so it holds however the VLAN comes to hand out addresses.
                '';
              };
              asn = lib.mkOption {
                type = lib.types.int;
                default = 65002;
                description = ''
                  The speaker's autonomous system number, from the 16-bit private
                  range. frrdev on the dev0 VLAN uses 65001 (see the server's
                  dev.nix), so the two can run side by side.
                '';
              };
              bfd = lib.mkOption {
                type = lib.types.bool;
                default = true;
                description = ''
                  Run BFD with the speaker, as the peers option does per peer.
                '';
              };
              debug = lib.mkOption {
                type = lib.types.bool;
                default = false;
                description = ''
                  Turn on BIRD `debug { states, events }` for the lab session, so
                  its state changes and events reach the journal, and thus Loki
                  under {host="routnerr-3", unit="bird.service"}.
                '';
              };
              families = {
                ipv6 = lib.mkOption {
                  type = lib.types.bool;
                  default = true;
                  description = "Carry IPv6 unicast on the session.";
                };
                ipv4 = lib.mkOption {
                  type = lib.types.bool;
                  default = true;
                  description = ''
                    Carry IPv4 unicast on the session, with the RFC 8950 extended
                    next hop, the way the dn42 peers do.

                    A speaker which does not advertise extended next hop still
                    establishes and still receives the IPv4 routes: the channel
                    names our own dn42 address as the next hop, since the VLAN
                    carries none of its own. So this is safe to leave on while a
                    speaker's extended next hop support is being written; what
                    changes when it lands is the next hop the speaker sees.
                  '';
                };
              };
            };
          }
        )
      );
    };
  };

  config = {
    # wg show is how to read a tunnel's handshake and transfer counters at
    # the shell, the same data the exporter below publishes; bird2 (which
    # carries birdc) arrives with services.bird.
    environment.systemPackages = [ pkgs.wireguard-tools ];

    assertions =
      let
        ports = lib.mapAttrsToList (_: peer: peer.port) cfg.peers;
      in
      [
        {
          assertion = lib.all (
            peer: lib.hasPrefix "dn42e-" peer.interface && lib.stringLength peer.interface <= 15
          ) (lib.attrValues cfg.peers);
          message = "dn42 peer interfaces must be dn42e-<name> and at most 15 characters";
        }
        {
          assertion = lib.unique ports == ports;
          message = "dn42 peers must use unique WireGuard listen ports";
        }
      ]
      ++ lib.mapAttrsToList (name: vlan: {
        assertion = !vlan.session || vlan.families.ipv6 || vlan.families.ipv4;
        message = "the dn42i-${name} session needs at least one address family";
      }) cfg.vlans
      ++ [
      ];

    # The tunnels share one WireGuard private key, whose public half is the
    # publicKey option above. Declared only when a peer exists, since
    # nothing but a tunnel reads it.
    sops.secrets."dn42/wireguard_key" = lib.mkIf (cfg.peers != { }) {
      sopsFile = cfg.secretsFile;
      owner = "systemd-network";
      restartUnits = [ "systemd-networkd.service" ];
    };

    systemd.network = {
      # A dummy interface holds the router's own dn42 addresses: stable for
      # BGP router id, loopback-style services (ns1, see coredns.nix), and
      # as the source of router-originated dn42 traffic.
      netdevs = {
        "50-dn42" = {
          netdevConfig = {
            Name = "dn42";
            Kind = "dummy";
          };
        };
      }
      // lib.mapAttrs' (
        _: vlan:
        lib.nameValuePair "50-${vlan.interface}" {
          netdevConfig = {
            Name = vlan.interface;
            Kind = "vlan";
          };
          vlanConfig.Id = vlan.vlan;
        }
      ) cfg.vlans
      // peerNetdevs;

      networks = {
        "50-dn42" = {
          matchConfig.Name = "dn42";
          address = [
            "${cfg.addr4}/32"
            "${cfg.addr6}/128"
          ];
        };
      }
      // lib.mapAttrs' (
        _: vlan:
        # IPv6 comes from router advertisements: CoreRAD serves net6 for
        # SLAAC on this interface and route information for dn42 (see
        # corerad.nix), with a zero router lifetime so hosts do not take
        # the router as a default route. IPv4 has neither DHCP nor a subnet:
        # hosts are assigned /32s from our allocation by hand and take the
        # router's own address as an on-link gateway, so the link route
        # below is how the router reaches them.
        lib.nameValuePair "50-${vlan.interface}" {
          matchConfig.Name = vlan.interface;
          address = [ "${vlan.addr6}/64" ];
          routes = lib.optional (vlan.onLink4 != null) {
            Destination = vlan.onLink4;
            Scope = "link";
            # The link has no IPv4 address of its own, so without this the
            # kernel sources router-originated traffic to a dn42 host from
            # the WAN. bird's routes get the same from krt_prefsrc; this
            # one is networkd's.
            PreferredSource = cfg.addr4;
          };
          networkConfig.IPv6AcceptRA = false;
        }
      ) cfg.vlans
      // peerNetworks;
    };

    # Courtesy of: https://dn42.dev/howto/Bird2.
    services.bird = {
      enable = true;
      # BIRD 2: the dn42 standard with the best-supported templates. The
      # nixpkgs default is bird3.
      package = pkgs.bird2;
      config = ''
        log syslog all;
        router id ${cfg.addr4};

        define OWNAS = ${toString cfg.asn};
        define OWNIP = ${cfg.addr4};
        define OWNIPv6 = ${cfg.addr6};

        # Our aggregates only; nothing of the homelab may ever be announced.
        define OWNNET = ${cfg.net4};
        define OWNNETv6 = ${cfg.net6};
        define OWNNETSET = [ ${cfg.net4}+ ];
        define OWNNETSETv6 = [ ${cfg.net6}+ ];

        function is_self_net() -> bool {
          return net ~ OWNNETSET;
        }

        function is_self_net_v6() -> bool {
          return net ~ OWNNETSETv6;
        }

        # The homelab site ULA: never learned from dn42, never announced.
        # Stating it here as hijack insurance costs nothing.
        define SITENETSETv6 = [ ${inventory.ulaPrefix}+ ];
        function is_site_net_v6() -> bool {
          return net ~ SITENETSETv6;
        }

        # The valid dn42 address space and prefix lengths, including the
        # networks dn42 interconnects with, verbatim from the community
        # filter template at https://dn42.dev/howto/Bird2.
        function is_valid_network() -> bool {
          return net ~ [
            172.20.0.0/14{21,29}, # dn42
            172.20.0.0/24{28,32}, # dn42 anycast
            172.21.0.0/24{28,32}, # dn42 anycast
            172.22.0.0/24{28,32}, # dn42 anycast
            172.23.0.0/24{28,32}, # dn42 anycast
            172.31.0.0/16+,       # ChaosVPN
            10.100.0.0/14+,       # ChaosVPN
            10.127.0.0/16+,       # neonetwork
            10.0.0.0/8{15,24}     # Freifunk
          ];
        }

        function is_valid_network_v6() -> bool {
          return net ~ [ fd00::/8{44,64} ];
        }

        # ROA data from dn42 RTR servers; multiple sources feed the same
        # tables for redundancy. Servers and the refresh/retry/expire
        # values are from the service list at
        # https://dn42.dev/services/RPKI. Routes are rejected unless
        # ROA_VALID, so a total RTR outage past the expire window fails
        # closed: sessions stay up but carry no routes.
        #
        # A mix of clearnet names and .dn42 names, the latter reached over
        # the network they validate. Different failure domains on purpose;
        # a .dn42 feed cannot resolve until dn42 is up, so a clearnet feed
        # always stays.
        roa4 table dn42_roa;
        roa6 table dn42_roa_v6;

        protocol rpki rpki_akaere {
          roa4 { table dn42_roa; };
          roa6 { table dn42_roa_v6; };
          remote "rpki.akae.re" port 8082;
          refresh 600;
          retry 300;
          expire 7200;
        }

        protocol rpki rpki_launchpadx {
          roa4 { table dn42_roa; };
          roa6 { table dn42_roa_v6; };
          remote "rpki.dn42.launchpadx.top" port 8082;
          refresh 600;
          retry 300;
          expire 7200;
        }

        protocol rpki rpki_routedbits {
          roa4 { table dn42_roa; };
          roa6 { table dn42_roa_v6; };
          remote "rpki.routedbits.dn42" port 8082;
          refresh 600;
          retry 300;
          expire 7200;
        }

        # A FlapAlerted feed, in tables of its own: it publishes an AS0 ROA
        # for a prefix that is currently flapping, to keep the flap from
        # spreading. It cannot share the tables above, where roa_check
        # answers ROA_VALID as soon as any covering ROA matches the origin
        # -- the legitimate ROA would outvote the AS0 one and the feed
        # would do nothing at all. A second feed would simply join these
        # tables: either operator flagging a prefix is enough to drop it.
        #
        # Fails open, unlike the tables above: lose the session and this
        # empties, every prefix reads ROA_UNKNOWN and nothing is
        # suppressed. The cost is that another operator gets a say in what
        # we accept, which is the bargain on offer.
        roa4 table dn42_flap_roa;
        roa6 table dn42_flap_roa_v6;

        protocol rpki rpki_sess_flap {
          roa4 { table dn42_flap_roa; };
          roa6 { table dn42_flap_roa_v6; };
          remote "rpki.sess.dn42" port 8282;
          refresh 600;
          retry 300;
          expire 7200;
        }

        # Unknown and invalid ROA both reject: a peer may only send us
        # prefixes it has registered. These rejections used to print, but
        # bird 2.19's filter language has no leveled print (only print and
        # printn, both fixed at the info class), so the line could not be
        # kept out of the journal without silencing every other info
        # message. A single flapping pair re-announcing every minute was
        # enough to drown the log. The rejected routes are still there to
        # look at: the channels below keep them filtered, so
        # `birdc show route filtered` names the prefix and its origin.
        filter dn42_import {
          if is_valid_network() && !is_self_net() then {
            if (roa_check(dn42_roa, net, bgp_path.last) != ROA_VALID) then reject;
            # AS0 when flapping, so INVALID rather than !VALID: a
            # prefix nobody has flagged is absent and reads UNKNOWN.
            if (roa_check(dn42_flap_roa, net, bgp_path.last) = ROA_INVALID) then reject;
            accept;
          }
          reject;
        }

        filter dn42_import_v6 {
          if is_valid_network_v6() && !is_self_net_v6() && !is_site_net_v6() then {
            if (roa_check(dn42_roa_v6, net, bgp_path.last) != ROA_VALID) then reject;
            # AS0 when flapping, so INVALID rather than !VALID: a
            # prefix nobody has flagged is absent and reads UNKNOWN.
            if (roa_check(dn42_flap_roa_v6, net, bgp_path.last) = ROA_INVALID) then reject;
            accept;
          }
          reject;
        }

        # Our own space leaves as the aggregate and nothing else. A second
        # site's prefixes arrive over an interconnect as more specifics of
        # OWNNET, and both is_valid_network and RTS_BGP would wave them
        # through -- announcing them is exactly the deaggregation dn42 asks
        # networks not to do.
        filter dn42_export {
          if is_self_net() && net != OWNNET then reject;
          if is_valid_network() && source ~ [ RTS_STATIC, RTS_BGP ] then accept;
          reject;
        }

        filter dn42_export_v6 {
          if is_site_net_v6() then reject;
          if is_self_net_v6() && net != OWNNETv6 then reject;
          if is_valid_network_v6() && source ~ [ RTS_STATIC, RTS_BGP ] then accept;
          reject;
        }

        ${lib.optionalString (cfg.ibgp != [ ]) ''
          # The interconnect carries our own more specifics, which dn42_import
          # rejects by design (is_self_net) -- reusing it here would discard
          # everything the far site sends. What crosses was ROA checked where
          # it entered our AS, so this is a sanity check, not a revalidation.
          # The site ULA stays rejected: it travels by the IGP, never by bird.
          filter dn42_ibgp_import {
            ${lib.optionalString cfg.ibgpInternal "if is_self_net() then accept;"}
            if is_valid_network() then accept;
            reject;
          }

          filter dn42_ibgp_import_v6 {
            if is_site_net_v6() then reject;
            ${lib.optionalString cfg.ibgpInternal "if is_self_net_v6() then accept;"}
            if is_valid_network_v6() then accept;
            reject;
          }

          filter dn42_ibgp_export {
            ${lib.optionalString cfg.ibgpInternal "if is_self_net() then accept;"}
            if is_valid_network() && source ~ [ RTS_STATIC, RTS_BGP ] then accept;
            reject;
          }

          filter dn42_ibgp_export_v6 {
            if is_site_net_v6() then reject;
            ${lib.optionalString cfg.ibgpInternal "if is_self_net_v6() then accept;"}
            if is_valid_network_v6() && source ~ [ RTS_STATIC, RTS_BGP ] then accept;
            reject;
          }
        ''}
        ${lib.optionalString (cfg.vlans != { }) ''
          # The internal session exports the two filters above unchanged,
          # so the speaker under development sees exactly what a dn42 peer
          # sees, and imports through these: nothing. Its channels keep
          # filtered routes, so `birdc show route filtered` shows what it
          # announced while none of it is in the table.
          #
          # The reject is the single choke point. Every other protocol here
          # exports out of the master tables - both kernel protocols, and
          # each dn42 peer session - so a route which never lands in a
          # master table can reach neither the FIB nor a peer, whatever the
          # speaker announces and whatever it writes in the AS_PATH. eBGP
          # loop detection on OWNAS stands behind that, not in front of it.
          #
          # To let the speaker originate test prefixes into dn42, drop the
          # reject and uncomment the guard: more specifics of our own
          # allocation, and nothing else. Not the aggregate itself, which
          # the static protocol below originates. Opening this also installs
          # what the speaker sends in the kernel's main table pointed at the
          # VLAN, so open it deliberately.
          filter dn42i_import_v6 {
            # if net ~ [ ${cfg.net6}{49,64} ] then accept;
            reject;
          }

          # dn42 accepts IPv4 down to /29 only (see is_valid_network), which
          # leaves exactly two test prefixes inside our /28.
          filter dn42i_import {
            # if net ~ [ ${cfg.net4}{29,29} ] then accept;
            reject;
          }
        ''}

        protocol device {
          scan time 10;
        }

        # Originate our aggregates as unreachable routes: bird announces
        # them to peers, and their kernel export terminates packets for
        # unused parts of the allocations instead of looping them back out
        # a tunnel. More-specific deployed routes override them, the same
        # pattern as the site ULA /48 unreachable route in networking.nix.
        protocol static {
          ipv4;
          route ${cfg.net4} unreachable;
        }

        protocol static {
          ipv6;
          route ${cfg.net6} unreachable;
        }

        # dn42 routes land in the kernel's main table: the space cannot
        # overlap production routing, and imports are filtered above.
        # Enslaving the tunnels to a Linux VRF (bird: vrf "name" per
        # protocol) is the stronger isolation if ever wanted, at the cost
        # of VRF-aware services and route leaking for LAN clients. prefsrc
        # makes router-originated dn42 traffic use our dn42 addresses.
        #
        # Both aggregates take their unreachable route into the kernel, so
        # traffic for the unassigned parts of an allocation terminates here
        # instead of following the default route out the WAN. The VLAN no
        # longer carries net4 on-link, so nothing else would catch it: its
        # link route covers only the addresses assigned there, and within
        # that an unassigned address still fails by ARP.
        protocol kernel {
          scan time 20;
          ipv4 {
            import none;
            export filter {
              if source = RTS_STATIC then accept;
              krt_prefsrc = OWNIP;
              accept;
            };
          };
        }

        protocol kernel {
          scan time 20;
          ipv6 {
            import none;
            export filter {
              if source = RTS_STATIC then accept;
              krt_prefsrc = OWNIPv6;
              accept;
            };
          };
        }

        protocol bfd {
          # Both interface classes, named rather than covered by one
          # wildcard: a bare dn42-* would match either prefix and quietly
          # merge them again.
          interface "dn42e-*", "dn42i-*" {
            min rx interval 200 ms;
            min tx interval 200 ms;
            idle tx interval 1000 ms;
            multiplier 5;
          };
        }

        # TODO: BMP export to a collector on linuxdev to feed the bmp
        # library a live dn42 stream; bird 2.19 ships experimental BMP.

        # Session shape follows the wiki's MP-BGP template
        # (https://dn42.dev/howto/Bird2): path metric, the 9000-route
        # import limit, and IPv4 with extended next hop over one IPv6
        # session all originate there.
        #
        # Both channels carry the same pair of table options:
        #
        #   import table on
        #     bird re-runs an import filter that calls roa_check whenever a
        #     ROA table changes ("rpki reload", on by default), but on a BGP
        #     channel it can only do so from a kept copy of the pre-filter
        #     routes. Without one it logs "Automatic RPKI reload not active
        #     for import" and a route rejected while a validator was cold
        #     stays rejected until the peer re-announces it. No export table:
        #     dn42_export has no roa_check to re-run.
        #
        #   import keep filtered on
        #     rejected routes stay in the table, hidden, so
        #     `birdc show route filtered` shows what the ROA check turned
        #     away. They count against the channel's filtered counter, not
        #     the import limit below.
        template bgp dnpeers {
          local as OWNAS;
          path metric on;

          ipv4 {
            # IPv4 routes with IPv6 next hops: one session per peer, no
            # IPv4 tunnel addressing needed. Every peer negotiates this;
            # one which declined would need `next hop address OWNIP` on
            # its own session, since a tunnel carries no IPv4 address for
            # bird to fall back on.
            extended next hop on;
            import filter dn42_import;
            export filter dn42_export;
            import limit 9000 action block;
            import table on;
            import keep filtered on;
          };

          ipv6 {
            import filter dn42_import_v6;
            export filter dn42_export_v6;
            import limit 9000 action block;
            import table on;
            import keep filtered on;
          };
        }

        ${peerProtocols}
        ${vlanProtocols}${ibgpProtocols}
      '';
    };

    # bird resolves its RPKI RTR servers by hostname, through the router's
    # own resolver (systemd-resolved to CoreDNS on loopback), which in turn
    # forwards external names over the uplink. So bird must not start until
    # both DNS and the uplink are up. Without this ordering a reboot can
    # bring bird up first: the RTR sessions fail to resolve, the ROA tables
    # stay empty, and the strict dn42 import filter then rejects every route
    # as ROA-unknown until bird is restarted by hand.
    systemd.services.bird = {
      after = [
        "coredns.service"
        "nss-lookup.target"
        "network-online.target"
      ];
      wants = [
        "coredns.service"
        "network-online.target"
      ];
    };

    # Scraped automatically by the server's Prometheus exporter discovery.
    services.prometheus.exporters.bird = {
      enable = true;
      birdVersion = 2;
    };

    # Tunnel health beneath the BGP sessions: handshake age and byte
    # counters per peer, discovered and scraped the same way. This is
    # MindFlavor's exporter from nixpkgs, which shells out to
    # `wg show all dump` under CAP_NET_ADMIN. Its metrics carry an
    # interface label, so dn42e-<peer> already names the peer; the
    # exporter's friendly name mapping reads a wg-quick configuration file,
    # which these networkd-managed tunnels do not have, and would only
    # repeat what the interface name says.
    services.prometheus.exporters.wireguard = {
      enable = true;
      # Export the age of each peer's last handshake alongside its UNIX
      # timestamp, so the alert compares one number to a threshold rather
      # than subtracting the router's clock from the server's.
      latestHandshakeDelay = true;
    };

    # Latency to each external peer across its tunnel, for the
    # DN42PeerLatencyHigh alert, plus a full-size echo at the tunnel's MTU
    # (the mtu option above) for DN42PeerMTUBlackhole, since a path that
    # drops packets of the configured size leaves the session looking
    # healthy. It runs here because a link-local address is only reachable
    # from the interface it lives on, and the tunnels are on this machine;
    # each peer is passed as its link-local address with the tunnel as the
    # zone, fe80::x%dn42e-<peer>, so a new peer is probed as soon as it is
    # declared. External peers only: the internal dn42i-* VLANs are not
    # tunnels and have no peer entry.
    systemd.services.dn42-peer-exporter = lib.mkIf (cfg.peers != { }) {
      description = "Prometheus dn42 peer exporter";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        ExecStart = utils.escapeSystemdExecArgs (
          [ "${dn42_peer_exporter}/bin/dn42_peer_exporter" ]
          ++ lib.mapAttrsToList (name: peer: "-peer=${name}=${peer.lla}%${peer.interface}") cfg.peers
        );
        Restart = "always";

        # The raw ICMPv6 socket needs CAP_NET_RAW, and it must be granted in
        # both places: systemd intersects the ambient set with the bounding
        # set, so an ambient grant alone is dropped and the socket fails to
        # open. Everything else is locked down.
        DynamicUser = true;
        AmbientCapabilities = [ "CAP_NET_RAW" ];
        CapabilityBoundingSet = [ "CAP_NET_RAW" ];
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        ProtectKernelTunables = true;
        ProtectControlGroups = true;
        RestrictNamespaces = true;
      };
    };
  };
}
