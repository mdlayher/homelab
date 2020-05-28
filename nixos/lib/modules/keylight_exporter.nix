{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.keylight_exporter;
in {
  options.services.keylight_exporter = {
    enable = mkEnableOption "Elgato Key Light Prometheus exporter";

    package = mkOption {
      default = pkgs.keylight_exporter;
      defaultText = "pkgs.keylight_exporter";
      type = types.package;
      description = "keylight_exporter package to use.";
    };
  };

  config = mkIf cfg.enable {
    systemd.services.keylight_exporter = {
      description = "Elgato Key Light Prometheus exporter";
      after = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        PermissionsStartOnly = true;
        LimitNPROC = 512;
        LimitNOFILE = 1048576;
        NoNewPrivileges = true;
        DynamicUser = true;
        ExecStart = "${getBin cfg.package}/bin/keylight_exporter";
        Restart = "on-failure";
      };
    };
  };
}
