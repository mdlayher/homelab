# consrv: SSH to serial console server for the machines with serial consoles
# attached to this Pi. Not packaged in nixpkgs, so built from source here.
{ pkgs, ... }:

let
  consrv = pkgs.buildGoModule rec {
    pname = "consrv";
    version = "1.2.1";

    src = pkgs.fetchFromGitHub {
      owner = "mdlayher";
      repo = "consrv";
      tag = "v${version}";
      hash = "sha256-dzodycyLw1l4uLupocZwi564qSxRPzA69W2mnhFX1qc=";
    };

    vendorHash = "sha256-n35qr0RcOHKOzpGzYV2DAefp899DHj2TQCpYfyg7ozQ=";

    subPackages = [ "cmd/consrv" ];
  };

  hostKey = "/var/lib/consrv/host_key";
in
{
  systemd.services.consrv = {
    description = "consrv serial console SSH server";
    documentation = [ "https://github.com/mdlayher/consrv" ];
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      # Generate a dedicated SSH host key on first start; sshd's host key
      # doubles as the sops decryption key and stays out of reach.
      ExecStartPre = pkgs.writeShellScript "consrv-host-key" ''
        if [ ! -f ${hostKey} ]; then
          ${pkgs.openssh}/bin/ssh-keygen -t ed25519 -N "" -C "" -f ${hostKey}
        fi
      '';
      ExecStart = "${consrv}/bin/consrv -c ${./consrv.toml} -k ${hostKey}";
      Restart = "on-failure";

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
