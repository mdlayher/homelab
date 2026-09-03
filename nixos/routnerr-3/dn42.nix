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
    lib.nameValuePair "50-dn42-${name}" {
      netdevConfig = {
        Name = "dn42-${name}";
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
    lib.nameValuePair "50-dn42-${name}" {
      matchConfig.Name = "dn42-${name}";
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
      protocol bgp ${birdName "dn42_${name}"} from dnpeers {
        neighbor ${peer.lla} % 'dn42-${name}' as ${toString peer.asn};
        ${lib.optionalString peer.bfd "bfd on;"}
      }
    '') cfg.peers
  );
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
        dn42-<name>. Adding the first peer requires the WireGuard private
        key secret dn42/wireguard_key in this host's secrets.yaml.
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

    # wg show is the only way to see a tunnel's handshake and transfer
    # counters; bird2 (which carries birdc) arrives with services.bird.
    environment.systemPackages = [ pkgs.wireguard-tools ];

    assertions =
      let
        ports = lib.mapAttrsToList (_: peer: peer.port) cfg.peers;
      in
      [
        {
          assertion = lib.all (name: lib.stringLength name <= 10) (lib.attrNames cfg.peers);
          message = "dn42 peer names must be <= 10 characters to fit ifname dn42-<name>";
        }
        {
          assertion = lib.unique ports == ports;
          message = "dn42 peers must use unique WireGuard listen ports";
        }
      ];

    # The tunnels share one WireGuard private key, generated once with
    # wg genkey and stored under dn42/wireguard_key; the public half is what
    # we hand to peers. Only referenced once a peer exists, so the machine
    # builds before the secrets file does.
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

        # Unknown and invalid ROA both reject; the log line is the fastest
        # way to spot a peer leaking unregistered prefixes.
        filter dn42_import {
          if is_valid_network() && !is_self_net() then {
            if (roa_check(dn42_roa, net, bgp_path.last) != ROA_VALID) then {
              print "[dn42] ROA check failed for ", net, " ASN ", bgp_path.last;
              reject;
            }
            accept;
          }
          reject;
        }

        filter dn42_import_v6 {
          if is_valid_network_v6() && !is_self_net_v6() && !is_site_net_v6() then {
            if (roa_check(dn42_roa_v6, net, bgp_path.last) != ROA_VALID) then {
              print "[dn42] ROA check failed for ", net, " ASN ", bgp_path.last;
              reject;
            }
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
          interface "dn42-*" {
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
          };

          ipv6 {
            import filter dn42_import_v6;
            export filter dn42_export_v6;
            import limit 9000 action block;
          };
        }

        ${peerProtocols}
      '';
    };

    # Scraped automatically by the server's Prometheus exporter discovery.
    services.prometheus.exporters.bird = {
      enable = true;
      birdVersion = 2;
    };
  };
}
