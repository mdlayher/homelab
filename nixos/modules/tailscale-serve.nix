# Tailscale Services hosted by this machine: stable service names
# (<name>.<tailnet>.ts.net) which decouple well-known endpoints from
# generation-numbered hostnames. The serve configuration is applied
# declaratively at activation; set-config --all overwrites everything, so
# removing a service here removes it from the node.
#
# The tailnet side is managed in the admin console: define each service
# (svc:<name>) with its tcp port, give this machine a tag-based identity, and
# approve it as a service host.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.homelab.tailscale.services;

  serveConfig = pkgs.writeText "tailscale-serve.json" (
    builtins.toJSON {
      version = "0.0.1";
      services = lib.mapAttrs' (
        name: endpoints: lib.nameValuePair "svc:${name}" { inherit endpoints; }
      ) cfg;
    }
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
      virtual IP to a local http://, https://, or tcp:// target.
    '';
  };

  config = lib.mkIf (cfg != { }) {
    systemd.services.tailscale-serve = {
      description = "Apply Tailscale Services serve configuration";
      after = [ "tailscaled.service" ];
      requires = [ "tailscaled.service" ];
      wantedBy = [ "multi-user.target" ];
      restartTriggers = [ serveConfig ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };

      # tailscaled may still be connecting at boot; failure after the retries
      # surfaces through the SystemdUnitFailed alert.
      script = ''
        for _ in $(seq 30); do
          ${tailscale}/bin/tailscale status >/dev/null 2>&1 && break
          sleep 2
        done
        exec ${tailscale}/bin/tailscale serve set-config ${serveConfig} --all
      '';
    };
  };
}
