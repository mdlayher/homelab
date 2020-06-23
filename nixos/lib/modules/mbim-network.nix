{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.mbim-network;

  # Transforms "/dev/cdc-wdm0" into "mbim-network-dev-cdc-wdm0" for file and
  # systemd unit names.
  cleanName = name: "mbim-network${replaceStrings [ "/" ] [ "-" ] name}";

  makeSystemdUnit = dcfg: name:
    let
      # Config file format defined in 'man 1 mbim-network'.
      configFile = with dcfg;
        pkgs.writeText "${cleanName name}.conf" ''
          APN=${apn}
          PROXY=${if cfg.proxy then "yes" else "no"}
          ${optionalString (apnUser != "") "APN_USER=${apnUser}"}
          ${optionalString (apnPass != "") "APN_PASS=${apnPass}"}
          ${optionalString (apnAuth != "") "APN_AUTH=${apnAuth}"}
        '';

      # Mimic the format of the commands run by mbim-network, including the
      # optional use of mbim-proxy.
      cliCmd = "${getBin pkgs.libmbim}/bin/mbimcli -d ${name}${
          optionalString cfg.proxy " --device-open-proxy"
        }";

      netCmd = "${
          getBin pkgs.libmbim
        }/bin/mbim-network --profile ${configFile} ${name}";
    in {
      description = "mbim-network for '${name}'";
      wantedBy = [ "multi-user.target" ];
      path = [ "${getBin pkgs.libmbim}" ];

      serviceConfig = {
        # 'mbim-network start' is a one-shot command which establishes the proper
        # state for MBIM modem communications. The equivalent 'stop' command
        # tears down the connection when the systemd unit stopped.
        User = "root";
        Type = "oneshot";
        RemainAfterExit = "yes";
        ExecStart = "${netCmd} start";
        ExecStop = "${netCmd} stop";
      };

      # Ensure the connection was started and an IP configuration can be fetched.
      postStart = ''
        ${netCmd} status | grep -q 'Status: activated'
        ${cliCmd} --query-ip-configuration
      '';
      postStop = "${netCmd} status | grep -q 'Status: deactivated'";
    };
in {
  options.services.mbim-network = {
    # Allow configuring zero or more MBIM devices with differing configurations.
    devices = mkOption {
      default = { };
      example = literalExample ''"/dev/cdc-wdm0".apn = "internet";'';
      type = with types;
        attrsOf (submodule {
          options = {
            apn = mkOption {
              type = types.str;
              example = "internet";
              description = ''
                The Access Point Name (APN) to use when starting mbim-network for
                this device. For a list of common APN values, see
                <link xlink:href="https://customer.cradlepoint.com/s/article/access-point-names-by-carrier"/>.
              '';
            };

            apnUser = mkOption {
              type = types.str;
              default = "";
              example = "user";
              description =
                "An optional username to use for APN authentication.";
            };

            apnPass = mkOption {
              type = types.str;
              default = "";
              example = "password";
              description =
                "An optional password to use for APN authentication.";
            };

            apnAuth = mkOption {
              type = types.enum [ "" "PAP" "CHAP" "MSCHAPV2" ];
              default = "";
              description = ''
                An optional authentication protocol to use for APN authentication:
                one of "" (none), "PAP", "CHAP", or "MSCHAPV2".
              '';
            };
          };
        });
    };

    proxy = mkOption {
      type = types.bool;
      # It seems that mbim-proxy greatly improves the responsiveness of
      # mbimcli commands, so we should encourage users to use it by default.
      default = true;
      description =
        "Whether or not to spawn mbim-proxy to proxy communications with MBIM devices.";
    };
  };

  # For each configured device, create a systemd unit to run mbim-network.
  config = mkIf (cfg.devices != { }) {
    systemd.services = listToAttrs (mapAttrsFlatten
      (name: value: nameValuePair (cleanName name) (makeSystemdUnit value name))
      cfg.devices);

    # TODO: consider adding systemd timers or similar to check the status of the
    # connection on an ongoing basis and to restart this unit if need be.
  };
}
