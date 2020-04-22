{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.wgipamd;
  configFile = pkgs.writeText "wgipamd.toml" cfg.config;
in {
  options.services.wgipamd = {
    enable = mkEnableOption "wgipamd WireGuard wg-dynamic server";

    config = mkOption {
      default = "";
      example = ''
        [storage]
        file = "/var/lib/wgipamd"
        [[interfaces]]
        name = "wg0"
      '';
      type = types.lines;
      description = ''
        Verbatim wgipamd TOML configuration. See <link xlink:href="https://github.com/mdlayher/wgipam/blob/master/internal/config/default.toml"/> for details.'';
    };

    package = mkOption {
      default = pkgs.wgipamd;
      defaultText = "pkgs.wgipamd";
      type = types.package;
      description = "wgipamd package to use.";
    };
  };

  config = mkIf cfg.enable {
    systemd.services.wgipamd = {
      description = "wgipamd WireGuard wg-dynamic server";
      after = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        PermissionsStartOnly = true;
        LimitNPROC = 512;
        LimitNOFILE = 1048576;
        CapabilityBoundingSet = "cap_net_bind_service";
        AmbientCapabilities = "cap_net_bind_service";
        NoNewPrivileges = true;
        DynamicUser = true;
        ExecStart = "${getBin cfg.package}/bin/wgipamd -c=${configFile}";
        Restart = "on-failure";
      };
    };
  };
}
