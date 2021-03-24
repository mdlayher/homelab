{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.conprof;
  configFile = pkgs.writeText "conprof.yaml" cfg.config;

  cmdlineArgs = [
    "sampler"
    "--config.file ${configFile}"
    "--log.level debug"
    "--http-address :10902"
    "--store=grpc.polarsignals.com:443"
    "--bearer-token=TODO"
  ];

in {
  options.services.conprof = {
    enable = mkEnableOption "conprof continuous profiler";

    config = mkOption {
      default = "";
      type = types.lines;
      description = ''
        Verbatim conprof YAML configuration. See <link xlink:href="https://github.com/conprof/conprof/blob/master/examples/conprof.yaml"/> for details.'';
    };

    package = mkOption {
      default = pkgs.conprof;
      defaultText = "pkgs.conprof";
      type = types.package;
      description = "conprof package to use.";
    };
  };

  config = mkIf cfg.enable {
    users = {
      groups.conprof = { };
      users.conprof = {
        description = "conprof daemon user";
        group = "conprof";
        createHome = true;
        home = "/var/lib/conprof";
      };
    };

    systemd.services.conprof = {
      description = "conprof continuous profiler";
      after = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        PermissionsStartOnly = true;
        LimitNPROC = 512;
        LimitNOFILE = 1048576;
        NoNewPrivileges = true;
        ExecStart = "${cfg.package}/bin/conprof"
          + optionalString (length cmdlineArgs != 0)
          (" \\\n  " + concatStringsSep " \\\n  " cmdlineArgs);
        Restart = "on-failure";
        User = "conprof";
      };
    };
  };
}
