{
  config,
  lib,
  pkgs,
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

let
  cfg = config.homelab.dn42;
  inventory = config.homelab.inventory;

  # bird protocol names allow underscores but not dashes.
  birdName = name: lib.replaceStrings [ "-" ] [ "_" ] name;

  # One WireGuard interface per peer: WireGuard routes internally by peer
  # public key, so multiple BGP peers cannot share an interface. All tunnels
  # share one private key, each with its own listen port.
  peerNetdevs = lib.mapAttrs' (
    name: peer:
    lib.nameValuePair "50-dn42e-${name}" {
      netdevConfig = {
        Name = "dn42e-${name}";
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
    name: _:
    lib.nameValuePair "50-dn42e-${name}" {
      matchConfig.Name = "dn42e-${name}";
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

  # One MP-BGP session per peer over IPv6 link-local, IPv4 carried with
  # extended next hop. BFD is opt-in per peer.
  peerProtocols = lib.concatStrings (
    lib.mapAttrsToList (name: peer: ''
      protocol bgp ${birdName "dn42e_${name}"} from dnpeers {
        neighbor ${peer.lla} % 'dn42e-${name}' as ${toString peer.asn};
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
  dev0Ifname = "dn42i-dev0";

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

  dev0Channels =
    lib.optionalString cfg.dev0.families.ipv6 ''
      ipv6 {
        import filter dn42i_import_v6;
        export filter dn42_export_v6;
        import limit 100 action block;
        import keep filtered on;
      };
    ''
    + lib.optionalString cfg.dev0.families.ipv4 ''
      ipv4 {
        # As with the dn42 peers: IPv4 NLRI over the one IPv6 session.
        extended next hop on;
        import filter dn42i_import;
        export filter dn42_export;
        import limit 100 action block;
        import keep filtered on;
      };
    '';

  dev0Protocol = ''
    protocol bgp dn42i_dev0 {
      local ${cfg.dev0.addr6} as OWNAS;
      neighbor ${cfg.dev0.neighbor} as ${toString cfg.dev0.asn};

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
      ${lib.optionalString cfg.dev0.bfd "bfd on;"}

      ${indentTail "  " dev0Channels}
    }
  '';
in
{
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
    peers = lib.mkOption {
      default = { };
      description = ''
        dn42 peers, keyed by a short name used in the interface name
        dn42e-<name>. All tunnels share the WireGuard private key secret
        dn42/wireguard_key in this host's secrets.yaml.
      '';
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
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
      );
    };

    # dn42i-dev0: the internal dn42 VLAN and the BGP session it carries,
    # for the implementation under development in the dev0 container. Named
    # for its link the way a peer's session is, so it inherits the internal
    # class's firewall and bird policy from its name.
    dev0 = {
      enable = lib.mkEnableOption ''
        the internal dn42 VLAN dn42i-dev0 and its BGP session. The router
        exports the dn42 tables over it, so the speaker sees the real
        routing table rather than synthetic prefixes, and imports nothing
        from it
      '';
      vlan = lib.mkOption {
        type = lib.types.int;
        default = 42;
        description = ''
          VLAN id, tagged on the same trunk as the site LANs; the parent
          interface lists it in networking.nix. 42 is a mnemonic, well
          clear of the site VLAN ids.
        '';
      };
      net6 = lib.mkOption {
        type = lib.types.str;
        default = "fde4:d0ad:ee0f:1::/64";
        description = ''
          The /64 carried on the VLAN, from our registered allocation. The
          second one, not the first: the router's own dn42 address sits at
          the very start of the first /64 on the dummy interface, and a
          /128 there plus an on-link /64 covering it is needlessly muddy.
        '';
      };
      addr6 = lib.mkOption {
        type = lib.types.str;
        default = "fde4:d0ad:ee0f:1::1";
        description = "The router's address on the VLAN, and the BGP local address.";
      };
      addr4 = lib.mkOption {
        type = lib.types.str;
        default = "172.20.140.82";
        description = ''
          The router's IPv4 address on the VLAN, carried as a /32.

          It exists so the IPv4 channel has a valid next hop to fall back
          on when a peer declines extended next hop; bird takes one from
          the session's interface, and an IPv6-only link leaves it none.

          A /32 rather than the whole /28 on-link, which the dn42 client
          plan eventually wants here: the router already originates
          172.20.140.80/28 as an unreachable static, and a connected route
          for the same prefix would compete with it in the FIB. Worth
          settling when clients actually arrive, not before.
        '';
      };
      neighbor = lib.mkOption {
        type = lib.types.str;
        default = "fde4:d0ad:ee0f:1::10";
        description = ''
          The speaker's address on the VLAN, and the only BGP neighbor the
          router accepts there. Chosen rather than learned, so that it
          holds however the VLAN comes to hand out addresses.
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

            A peer which does not advertise extended next hop still
            establishes and still receives the IPv4 routes: bird falls back
            to an IPv4 next hop, its own address on the link, rather than
            refusing the family. So this is safe to leave on while a
            speaker's extended next hop support is being written; what
            changes when it lands is the next hop the speaker sees. See
            addr4 for why the link needs an IPv4 address at all.
          '';
        };
      };
    };
  };

  config = {
    # Kioubit: https://dn42.g-load.eu.
    homelab.dn42.peers.kioubit = {
      asn = 4242423914;
      publicKey = "6Cylr9h1xFduAO+5nyXhFI1XJ0+Sw9jCpCDvcqErF1s=";
      endpoint = "us2.g-load.eu:20060";
      port = 23914;
      lla = "fe80::ade0";
    };

    # highdef: https://highdef.network.
    homelab.dn42.peers.highdef = {
      asn = 4242421080;
      publicKey = "u4WJMAoCHIOeh/+6NWMytNygp+/wrMogB+rwyVzXoEg=";
      endpoint = "chi.peer.highdef.network:23610";
      port = 21080;
      lla = "fe80::113";
    };

    # dn42i-dev0, carrying the session with wipbgpd in the development
    # container. The container is not attached to the VLAN yet, so the
    # session sits idle until it is; see the server's dev.nix.
    homelab.dn42.dev0.enable = true;

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
          assertion = lib.all (name: lib.stringLength name <= 9) (lib.attrNames cfg.peers);
          message = "dn42 peer names must be <= 9 characters to fit ifname dn42e-<name>";
        }
        {
          assertion = lib.unique ports == ports;
          message = "dn42 peers must use unique WireGuard listen ports";
        }
        {
          assertion = !cfg.dev0.enable || cfg.dev0.families.ipv6 || cfg.dev0.families.ipv4;
          message = "the dn42i-dev0 session needs at least one address family";
        }
      ];

    # The tunnels share one WireGuard private key, generated once with
    # wg genkey and stored under dn42/wireguard_key. The public half is not
    # a secret; it is what we hand to peers, so keep it here rather than
    # decrypting the private key to recover it:
    #
    #   yHaVotqyBwnDqT9mj4t28fFnpLyAGosU3gOq/ngmkHk=
    #
    # Declared only when a peer exists, since nothing but a tunnel reads it.
    sops.secrets."dn42/wireguard_key" = lib.mkIf (cfg.peers != { }) {
      sopsFile = ./secrets.yaml;
      owner = "systemd-network";
      restartUnits = [ "systemd-networkd.service" ];
    };

    systemd.network = {
      # A dummy interface holds the router's own dn42 addresses: stable for
      # BGP router id, loopback-style services (future ns1.mdlayher.dn42),
      # and as the source of router-originated dn42 traffic.
      netdevs = {
        "50-dn42" = {
          netdevConfig = {
            Name = "dn42";
            Kind = "dummy";
          };
        };
      }
      // lib.optionalAttrs cfg.dev0.enable {
        "50-${dev0Ifname}" = {
          netdevConfig = {
            Name = dev0Ifname;
            Kind = "vlan";
          };
          vlanConfig.Id = cfg.dev0.vlan;
        };
      }
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
      // lib.optionalAttrs cfg.dev0.enable {
        # No DHCP server and no router advertisements yet: nothing on the
        # VLAN needs them while both ends are configured by hand. The dn42
        # client plan wants advertisements shaped quite differently from a
        # site LAN's (route information, zero default router lifetime), so
        # they arrive with the clients rather than ahead of them.
        "50-${dev0Ifname}" = {
          matchConfig.Name = dev0Ifname;
          address = [
            "${cfg.dev0.addr6}/64"
            "${cfg.dev0.addr4}/32"
          ];
          networkConfig.IPv6AcceptRA = false;
        };
      }
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

        # ROA data from clearnet-reachable dn42 RTR servers; two sources
        # feed the same tables for redundancy. Servers and the
        # refresh/retry/expire values are from the service list at
        # https://dn42.dev/services/RPKI. Routes are rejected unless
        # ROA_VALID, so a total RTR outage past the expire window fails
        # closed: sessions stay up but carry no routes.
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
            accept;
          }
          reject;
        }

        filter dn42_import_v6 {
          if is_valid_network_v6() && !is_self_net_v6() && !is_site_net_v6() then {
            if (roa_check(dn42_roa_v6, net, bgp_path.last) != ROA_VALID) then reject;
            accept;
          }
          reject;
        }

        filter dn42_export {
          if is_valid_network() && source ~ [ RTS_STATIC, RTS_BGP ] then accept;
          reject;
        }

        filter dn42_export_v6 {
          if is_site_net_v6() then reject;
          if is_valid_network_v6() && source ~ [ RTS_STATIC, RTS_BGP ] then accept;
          reject;
        }

        ${lib.optionalString cfg.dev0.enable ''
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
            # IPv4 tunnel addressing needed.
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
        ${lib.optionalString cfg.dev0.enable dev0Protocol}
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
  };
}
