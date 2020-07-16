{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.modemmanager_exporter;
in {
  options.services.modemmanager_exporter = {
    enable = mkEnableOption "ModemManager Prometheus exporter";

    package = mkOption {
      default = pkgs.modemmanager_exporter;
      defaultText = "pkgs.modemmanager_exporter";
      type = types.package;
      description = "modemmanager_exporter package to use.";
    };
  };

  config = mkIf cfg.enable {
    systemd.services.modemmanager_exporter = {
      description = "ModemManager Prometheus exporter";
      after = [ "network-online.target" "ModemManager.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        PermissionsStartOnly = true;
        LimitNPROC = 512;
        LimitNOFILE = 1048576;
        NoNewPrivileges = true;
        User = "modemmanager_exporter";
        Group = "networkmanager";
        ExecStart = "${getBin cfg.package}/bin/modemmanager_exporter";
        Restart = "on-failure";
      };
    };

    users.users.modemmanager_exporter = {
      group = "networkmanager";
      isSystemUser = true;
    };
  };
}
