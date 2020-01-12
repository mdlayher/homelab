{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.corerad;
  configFile = pkgs.writeText "corerad.toml" cfg.config;
in {
  options.services.corerad = {
    enable = mkEnableOption "CoreRAD IPv6 NDP RA daemon";

    config = mkOption {
      default = "";
      example = ''
        [[interfaces]]
        name = "eth0"
        send_advertisements = true
      '';
      type = types.lines;
      description = ''
        Verbatim CoreRAD TOML configuration. See <link xlink:href="https://github.com/mdlayher/corerad/blob/master/internal/config/default.toml"/> for details.'';
    };

    package = mkOption {
      default = pkgs.corerad;
      defaultText = "pkgs.corerad";
      type = types.package;
      description = "CoreRAD package to use.";
    };
  };

  config = mkIf cfg.enable {
    systemd.services.corerad = {
      description = "CoreRAD IPv6 NDP RA daemon";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        PermissionsStartOnly = true;
        LimitNPROC = 512;
        LimitNOFILE = 1048576;
        CapabilityBoundingSet = "cap_net_raw cap_net_admin";
        AmbientCapabilities = "cap_net_raw cap_net_admin";
        NoNewPrivileges = true;
        DynamicUser = true;
        ExecStart = "${getBin cfg.package}/bin/corerad -c=${configFile}";
        Restart = "on-failure";
      };
    };
  };
}
