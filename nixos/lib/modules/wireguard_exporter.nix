{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.wireguard_exporter;
  configFile = pkgs.writeText "wireguard_exporter.toml" cfg.config;
in {
  options.services.wireguard_exporter = {
    enable = mkEnableOption "WireGuard Prometheus exporter";

    # TODO: nixify.
    config = mkOption {
      default = "";
      type = types.lines;
      description = "Peer mappings TOML configuration.";
    };

    package = mkOption {
      default = pkgs.wireguard_exporter;
      defaultText = "pkgs.wireguard_exporter";
      type = types.package;
      description = "wireguard_exporter package to use.";
    };
  };

  config = mkIf cfg.enable {
    systemd.services.wireguard_exporter = {
      description = "WireGuard Prometheus exporter";
      after = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        PermissionsStartOnly = true;
        LimitNPROC = 512;
        LimitNOFILE = 1048576;
        CapabilityBoundingSet = "cap_net_admin";
        AmbientCapabilities = "cap_net_admin";
        NoNewPrivileges = true;
        DynamicUser = true;
        ExecStart = "${
            getBin cfg.package
          }/bin/wireguard_exporter -wireguard.peer-file=${configFile}";
        Restart = "on-failure";
      };
    };
  };
}
