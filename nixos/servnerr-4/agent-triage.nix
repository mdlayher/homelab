# A first diagnosis for every alert group that starts firing: Alertmanager
# posts the group here as well as to Discord, and an agent investigates it
# with the read-only query helpers, sending its findings to the main agent
# session and to the alerts channel. Built from go/internal/agent_triage.
#
# The agent runs inside the development container, where its helpers, the
# repository and its login live, as the admin user. This service runs on the
# host because the Discord webhook is a sops secret and the containers run no
# sops; it hands the prompt and the output through files in the container's
# root and starts the agent with systemd-run --machine, so the container's
# own configuration does not change.
{ config, pkgs, ... }:

let
  agent_triage = (pkgs.buildGoModule.override { go = pkgs.unstable.go_1_27; }) {
    pname = "agent_triage";
    version = "0.1.0";
    src = ../../go/internal/agent_triage;
    vendorHash = "sha256-uPqabZgQGQulf+F3BvMLhv4O0h5jOq12F7K60u5xjtA=";
  };

  container = "linuxdev";
  user = config.homelab.user;
in
{
  systemd.services.agent-triage = {
    description = "Agent diagnosis of newly firing alerts";
    after = [
      "network.target"
      "container@${container}.service"
    ];
    wantedBy = [ "multi-user.target" ];
    # systemd-run, to start the agent inside the container.
    path = [ config.systemd.package ];

    serviceConfig = {
      ExecStart = toString [
        "${agent_triage}/bin/agent_triage"
        "-discord-url-file=%d/discord_webhook_url"
        "-machine=${container}"
        "-container-root=/var/lib/nixos-containers/${container}"
        "-user=${user}"
        "-workdir=/home/${user}/src/homelab/main"
        "-model=sonnet"
      ];
      LoadCredential = [
        "discord_webhook_url:${config.sops.secrets."discord/alerts_webhook_url".path}"
      ];
      Restart = "always";

      # Root, to start units inside the container and write the handoff
      # files into its root; confined to that directory otherwise.
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ReadWritePaths = [ "/var/lib/nixos-containers/${container}/var/lib/agent-triage" ];
      ProtectHome = true;
      PrivateTmp = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
    };
  };

  # The handoff directory, inside the container's root.
  systemd.tmpfiles.rules = [
    "d /var/lib/nixos-containers/${container}/var/lib/agent-triage 0700 root root -"
  ];

  sops.secrets."discord/alerts_webhook_url".restartUnits = [ "agent-triage.service" ];
}
