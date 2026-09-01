# Tailscale Services hosted by this machine: stable service names
# (<name>.<tailnet>.ts.net) which decouple well-known endpoints from
# generation-numbered hostnames. The serve configuration is applied
# declaratively at activation; set-config --all overwrites everything, so
# removing a service here removes it from the node.
#
# The tailnet side is managed in terraform/tailscale/: services.tf defines
# each service (svc:<name>) with its tcp ports, and policy.hujson auto-approves
# this machine as a service host by its tag. The machine's tag-based identity
# itself is assigned in the admin console.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.homelab.tailscale.services;

  # The configuration file format cannot express TLS termination as of
  # tailscale 1.102 (its TCP apply path only accepts tcp:// and unix://
  # targets), so those endpoints are split out and applied with the CLI's
  # --tls-terminated-tcp flag after the base configuration.
  isTLS = target: lib.hasPrefix "tls-terminated-tcp://" target;

  baseServices = lib.filterAttrs (_: endpoints: endpoints != { }) (
    lib.mapAttrs (_: lib.filterAttrs (_: target: !isTLS target)) cfg
  );

  serveConfig = pkgs.writeText "tailscale-serve.json" (
    builtins.toJSON {
      version = "0.0.1";
      services = lib.mapAttrs' (
        name: endpoints: lib.nameValuePair "svc:${name}" { inherit endpoints; }
      ) baseServices;
    }
  );

  tlsCommands = lib.concatLists (
    lib.mapAttrsToList (
      name: endpoints:
      lib.mapAttrsToList (
        port: target:
        "${tailscale}/bin/tailscale serve --service=svc:${name} "
        + "--tls-terminated-tcp=${lib.removePrefix "tcp:" port} "
        + lib.removePrefix "tls-terminated-tcp://" target
      ) (lib.filterAttrs (_: isTLS) endpoints)
    ) cfg
  );

  tailscale = config.services.tailscale.package;
in
{
  options.homelab.tailscale.services = lib.mkOption {
    type = lib.types.attrsOf (lib.types.attrsOf lib.types.str);
    default = { };
    example = {
      grafana."tcp:80" = "http://127.0.0.1:3000";
    };
    description = ''
      Tailscale Services hosted by this machine: service names (without the
      svc: prefix) to endpoint mappings of "tcp:<port>" on the service's
      virtual IP to a local http://, https://, tcp://, or
      tls-terminated-tcp:// target. The target scheme selects the serve mode:
      tls-terminated-tcp terminates TLS with a certificate for the service
      name and forwards plaintext to the local port.
    '';
  };

  config = lib.mkIf (cfg != { }) {
    systemd.services.tailscale-serve = {
      description = "Apply Tailscale Services serve configuration";
      after = [ "tailscaled.service" ];
      requires = [ "tailscaled.service" ];
      wantedBy = [ "multi-user.target" ];
      restartTriggers = [
        serveConfig
        (builtins.toJSON tlsCommands)
      ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };

      # tailscaled may still be connecting at boot; failure after the retries
      # surfaces through the SystemdUnitFailed alert. set-config --all clears
      # all previous serve state before the TLS endpoints are layered on, so
      # each run converges on exactly this configuration.
      script = ''
        for _ in $(seq 30); do
          ${tailscale}/bin/tailscale status >/dev/null 2>&1 && break
          sleep 2
        done
        # Flags must precede the filename despite the CLI's usage string.
        ${tailscale}/bin/tailscale serve set-config --all ${serveConfig}
        ${lib.concatLines tlsCommands}
      '';
    };
  };
}
