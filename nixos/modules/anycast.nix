# Service addresses held at more than one site at once: one /128 per
# service, on a dummy every answering node carries, advertised by the IGP so
# a client reaches whichever node is nearest.
#
# The registry is nixos/inventory/default.nix, and it is plain data because
# both halves of the arrangement read it: the node which answers, and the
# client and firewall which name the address. This module is the answering
# half.
#
# An anycast address which cannot be withdrawn is worse than one server,
# since a dead node keeps attracting the clients nearest to it, because it
# is nearest. So each address follows its own service: a passive interface
# advertises the prefixes on it as independent prefixes, and removing one
# withdraws that service while the rest stay advertised.
#
# The dummy has no matching .network, so networkd creates the link and
# manages nothing on it. Ownership of the addresses is then the units'
# alone. On a managed link it would rest on KeepConfiguration=, which
# defaults to dropping addresses networkd did not configure itself.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.homelab.anycast;
  inventory = config.homelab.inventory;

  interface = "anycast";
  ip = "${pkgs.iproute2}/bin/ip";
  device = "sys-subsystem-net-devices-${interface}.device";
in
{
  options.homelab.anycast.services = lib.mkOption {
    default = { };
    description = ''
      The services this machine answers at an anycast address, keyed by the
      inventory's name for that address. Declared by whatever configures the
      service, since an address is only honest while the service behind it
      is answering.
    '';
    type = lib.types.attrsOf (
      lib.types.submodule (
        { name, ... }:
        {
          options = {
            address = lib.mkOption {
              type = lib.types.str;
              default = inventory.anycast.${name};
              defaultText = lib.literalExpression "the inventory's anycast address of this name";
              description = "The address this node holds while the unit below is running.";
            };

            unit = lib.mkOption {
              type = lib.types.str;
              description = ''
                The unit which answers there. The address is added once that
                unit is up and removed when it stops, so a node which has
                stopped serving stops being advertised.
              '';
            };
          };
        }
      )
    );
  };

  config = lib.mkIf (cfg.services != { }) {
    systemd.network.netdevs."50-anycast".netdevConfig = {
      Name = interface;
      Kind = "dummy";
    };

    # Advertised or invisible, as a loopback is: the module which puts the
    # addresses on the interface is the one which names it to the IGP.
    homelab.interconnect.isis.passiveInterfaces = [ interface ];

    systemd.services = {
      # networkd creates the device and leaves it down, having no network to
      # apply to it. A passive interface is advertised only while it is up.
      anycast = {
        description = "Anycast service interface";
        wantedBy = [ device ];
        bindsTo = [ device ];
        after = [ device ];

        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "${ip} link set up dev ${interface}";
        };
      };
    }
    // lib.mapAttrs' (
      name: service:
      lib.nameValuePair "anycast-${name}" {
        description = "Anycast address for ${name}";

        # Bound to both: the address means this node is serving, and it can
        # only sit on an interface which exists.
        bindsTo = [
          "anycast.service"
          service.unit
        ];
        after = [
          "anycast.service"
          service.unit
        ];
        # Wanted by the service so a restart of it brings the address back,
        # and by the target so activation starts this unit even when the
        # service itself is unchanged and therefore never restarted. Without
        # the second, a deploy which touches nothing the daemon reads leaves
        # the address off until the next reboot.
        wantedBy = [
          service.unit
          "multi-user.target"
        ];

        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "${ip} -6 address replace ${service.address}/128 dev ${interface}";
          # Ignore a failure to remove: the address may already be gone with
          # the interface, and the unit must still reach inactive.
          ExecStop = "-${ip} -6 address delete ${service.address}/128 dev ${interface}";
        };
      }
    ) cfg.services;
  };
}
