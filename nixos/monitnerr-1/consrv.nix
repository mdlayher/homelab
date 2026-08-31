# consrv: SSH to serial console server for the machines with serial consoles
# attached to this Pi. Not packaged in nixpkgs, so built from source here.
{ pkgs, ... }:

let
  consrv = pkgs.buildGoModule {
    pname = "consrv";
    version = "1.3.0";

    src = pkgs.fetchFromGitHub {
      owner = "mdlayher";
      repo = "consrv";
      rev = "v1.3.0";
      hash = "sha256-0tUt4fXqpWLmGXo9S4KBHafbyDickfbOCjLpZXERsDk=";
    };

    vendorHash = "sha256-/kU1hGu1LLHxy7Df7bu+9Qg6upu23BcV8j7xVOMFcTA=";

    subPackages = [ "cmd/consrv" ];
  };

  hostKey = "/var/lib/consrv/host_key";
in
{
  # Stable tailnet name for the serial consoles on the standard SSH port:
  # ssh router@consrv.<tailnet>.ts.net; see nixos/modules/tailscale-serve.nix.
  homelab.tailscale.services.consrv."tcp:22" = "tcp://127.0.0.1:2222";

  systemd.services.consrv = {
    description = "consrv serial console SSH server";
    documentation = [ "https://github.com/mdlayher/consrv" ];
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];

    # consrv enumerates USB serial adapters once at startup and exits if a
    # configured device is missing. At boot it races USB enumeration, so keep
    # restarting until the adapters appear rather than hitting the start limit.
    unitConfig.StartLimitIntervalSec = 0;

    serviceConfig = {
      # Generate a dedicated SSH host key on first start; sshd's host key
      # doubles as the sops decryption key and stays out of reach.
      ExecStartPre = pkgs.writeShellScript "consrv-host-key" ''
        if [ ! -f ${hostKey} ]; then
          ${pkgs.openssh}/bin/ssh-keygen -t ed25519 -N "" -C "" -f ${hostKey}
        fi
      '';
      ExecStart = "${consrv}/bin/consrv -c ${./consrv.toml} -k ${hostKey}";
      Restart = "always";
      RestartSec = 2;

      # Unprivileged, with access to USB serial devices via the dialout group.
      DynamicUser = true;
      SupplementaryGroups = [ "dialout" ];
      StateDirectory = "consrv";

      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectHome = true;
      ProtectSystem = "strict";
    };
  };
}
