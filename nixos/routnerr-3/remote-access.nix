{
  config,
  lib,
  ...
}:

# A WireGuard tunnel from devices off the tailnet into this site. Each
# device holds one address in the tunnel and reaches only the hosts and
# ports it lists; names on the tailnet resolve past an SSH host with
# ssh -J. nftables.nix admits each device's reaches and nothing else.

let
  inventory = config.homelab.inventory;
  cfg = config.homelab.remoteAccess;

  # This site's /64 of the carve-out, its index in the last two digits of
  # the hextet: the router at ::1, each device at its assigned host number.
  net6 = "${lib.removeSuffix "00::/56" inventory.remotePrefix6}${
    lib.fixedWidthNumber 2 inventory.sites.${config.homelab.site}.index
  }";

  devices = lib.attrValues cfg.devices;
  hosts = map (device: device.host) devices;
  targets = lib.unique (lib.concatMap (device: map (r: r.target) device.reaches) devices);
in
{
  options.homelab.remoteAccess = {
    interface = lib.mkOption {
      type = lib.types.str;
      default = "remote0";
      description = "The remote access WireGuard interface.";
    };
    port = lib.mkOption {
      type = lib.types.port;
      default = 51820;
      description = "UDP port the tunnel listens on, opened on the WANs in nftables.nix.";
    };
    devices = lib.mkOption {
      default = { };
      description = "Remote devices admitted to the tunnel, by name.";
      type = lib.types.attrsOf (
        lib.types.submodule (
          { config, ... }:
          {
            options = {
              publicKey = lib.mkOption {
                type = lib.types.str;
                description = "The device's WireGuard public key, from its client.";
              };
              host = lib.mkOption {
                type = lib.types.ints.between 2 9999;
                description = ''
                  The device's address in the tunnel, written as the last
                  hextet: 2 is ::2. Assigned rather than derived, so adding
                  or removing a device never renumbers another.
                '';
              };
              address = lib.mkOption {
                type = lib.types.str;
                readOnly = true;
                default = "${net6}::${toString config.host}";
                description = "The device's address in the tunnel, built from host.";
              };
              reaches = lib.mkOption {
                description = "What the device may initiate toward, by inventory host and port.";
                type = lib.types.listOf (
                  lib.types.submodule {
                    options = {
                      target = lib.mkOption {
                        type = lib.types.str;
                        description = "An inventory host at this site, reached at its ULA.";
                      };
                      protocol = lib.mkOption {
                        type = lib.types.enum [
                          "tcp"
                          "udp"
                        ];
                        default = "tcp";
                        description = "The transport protocol.";
                      };
                      port = lib.mkOption {
                        type = lib.types.port;
                        description = "The destination port.";
                      };
                    };
                  }
                );
              };
            };
          }
        )
      );
    };
  };

  config = {
    homelab.remoteAccess.devices.psframework = {
      publicKey = "TPjQairhxMGjiEjWNx5yBx/c8l2L3sYhG5SsxzOYAW4=";
      host = 2;
      reaches = [
        {
          target = "linuxdev";
          port = 22;
        }
      ];
    };

    assertions = [
      {
        assertion = lib.length hosts == lib.length (lib.unique hosts);
        message = "homelab: every remote access device needs a host number of its own.";
      }
      {
        assertion = lib.all (t: (inventory.hosts.${t} or { ula = null; }).ula != null) targets;
        message = "homelab: every remote access target must be an inventory host at this site with an IPv6 address.";
      }
    ];

    # Minted by `sops-gate keygen-wg`. The public half, which each remote
    # device's configuration names:
    # WuXwBLg8aqWw2kXzyTk2iLt5rZLrHZG9NcA7+uaG8U8=
    sops.secrets."remote/wireguard_key" = {
      sopsFile = ./secrets.yaml;
      owner = "systemd-network";
      restartUnits = [ "systemd-networkd.service" ];
    };

    systemd.network = {
      netdevs."50-${cfg.interface}" = {
        netdevConfig = {
          Name = cfg.interface;
          Kind = "wireguard";
        };
        wireguardConfig = {
          PrivateKeyFile = config.sops.secrets."remote/wireguard_key".path;
          ListenPort = cfg.port;
        };
        wireguardPeers = lib.mapAttrsToList (_: device: {
          PublicKey = device.publicKey;
          AllowedIPs = [ "${device.address}/128" ];
        }) cfg.devices;
      };

      networks."50-${cfg.interface}" = {
        matchConfig.Name = cfg.interface;
        address = [ "${net6}::1/64" ];
        networkConfig = {
          LinkLocalAddressing = "no";
          IPv6AcceptRA = false;
        };
        linkConfig.RequiredForOnline = "no";
      };
    };
  };
}
