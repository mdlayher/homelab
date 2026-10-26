# The tailnet's configuration audit log, pulled from Tailscale's API into
# the journal and so into Loki: every node added or removed, policy and
# settings write, key created and lock event, with who did it and from
# where. Tailscale keeps the log for a limited time; this keeps it, and
# loki.nix announces each change in the ops channel. A pull needs no
# inbound path from Tailscale, which webhooks would.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  # An OAuth client of its own, able to read this log and nothing else, so
  # the credential on this machine is worth nothing to a writer. systemd
  # reads both halves on the unit's behalf.
  clientId = config.sops.secrets."tailscale/audit_client_id".path;
  clientSecret = config.sops.secrets."tailscale/audit_client_secret".path;

  audit = pkgs.writers.writePython3Bin "tailnet-audit" { } (builtins.readFile ./tailnet-audit.py);
in
{
  sops.secrets."tailscale/audit_client_id" = { };
  sops.secrets."tailscale/audit_client_secret" = { };

  systemd = {
    timers.tailnet-audit = {
      description = "Pull the tailnet's configuration audit log";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "3m";
        OnUnitActiveSec = "5m";
      };
    };

    # Written to stdout for the reasons given in the router's network
    # snapshot; the lines arrive labeled unit="tailnet-audit.service", and
    # nixos/modules/alloy.nix gives them job="tailnet-audit".
    services.tailnet-audit = {
      description = "Tailnet configuration audit log";
      serviceConfig = {
        Type = "oneshot";
        DynamicUser = true;
        StateDirectory = "tailnet-audit";
        SyslogIdentifier = "tailnetaudit";
        LoadCredential = [
          "client_id:${clientId}"
          "client_secret:${clientSecret}"
        ];
        ExecStart = lib.getExe audit;
      };
    };
  };
}
