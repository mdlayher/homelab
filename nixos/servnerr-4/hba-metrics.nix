# Exports the SAS HBA's chip temperatures to Prometheus through
# node_exporter's textfile collector; the mpt3sas driver exposes no hwmon
# sensor, so Broadcom's storcli reads them. The card carries one SAS3008
# per controller, each with its own ROC (RAID-on-chip) sensor, and cools
# passively. See HBATemperatureHigh in alerts/hardware.nix.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  storcli = "${pkgs.storcli}/bin/storcli64";
  jq = "${pkgs.jq}/bin/jq";

  # One line per controller reporting a ROC temperature. Searched for by
  # property name rather than by path, since storcli's JSON nests it
  # differently across commands.
  program = ''
    .Controllers[]
    | ."Command Status".Controller as $c
    | .. | objects
    | select((.Ctrl_Prop? // "") | startswith("ROC temperature"))
    | "homelab_hba_temperature_celsius{controller=\"\($c)\"} \(.Value | tonumber)"
  '';
in
{
  systemd = {
    timers.hba-metrics = {
      description = "Sample SAS HBA temperatures for Prometheus";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "1m";
        OnUnitActiveSec = "1m";
      };
    };

    services.hba-metrics = {
      description = "SAS HBA temperature metrics for node_exporter";
      serviceConfig = {
        Type = "oneshot";
        # storcli writes its debug logs to the working directory.
        RuntimeDirectory = "hba-metrics";
        WorkingDirectory = "/run/hba-metrics";
      };

      # Renamed into place so a scrape never sees half a file, and a
      # failed run, or one which found no sensor, leaves the last good one.
      script = ''
        out=${config.homelab.textfileDir}/hba.prom

        lines=$(${storcli} /call show temperature J | ${jq} -r ${lib.escapeShellArg program})
        [ -n "$lines" ]

        {
          echo "# HELP homelab_hba_temperature_celsius Temperature of a SAS HBA controller's chip, as storcli reports it."
          echo "# TYPE homelab_hba_temperature_celsius gauge"
          echo "$lines"
        } > "$out.tmp"

        mv "$out.tmp" "$out"
      '';
    };
  };
}
