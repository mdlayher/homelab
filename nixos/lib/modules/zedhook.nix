{
  config,
  lib,
  pkgs,
  ...
}:

with lib;

let
  cfg = config.services.zedhook;
in
{
  options.services.zedhook = {
    enable = mkEnableOption "zedhook ZFS event monitoring system";

    package = mkOption {
      default = pkgs.zedhook;
      defaultText = "pkgs.zedhook";
      type = types.package;
      description = "zedhook package to use.";
    };
  };

  config = mkIf cfg.enable {
    # TODO: drop in all-zedhookd ZEDLET.

    users.groups.zedhookd = { };
    users.users.zedhookd = {
      description = "zedhookd daemon user";
      group = "zedhookd";
      isSystemUser = true;
    };

    systemd.services.zedhook = {
      description = "zedhook ZFS event monitoring system";
      after = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        PermissionsStartOnly = true;
        LimitNPROC = 512;
        LimitNOFILE = 1048576;
        NoNewPrivileges = true;
        ExecStart = "${getBin cfg.package}/bin/zedhookd -d /var/lib/zedhookd/zedhookd.db";
        User = "zedhookd";
        Restart = "always";
        RuntimeDirectory = "zedhookd";
        RuntimeDirectoryMode = "0700";
        WorkingDirectory = "/var/lib/zedhookd";
        StateDirectory = "zedhookd";
        StateDirectoryMode = "0700";
      };
    };
  };
}
