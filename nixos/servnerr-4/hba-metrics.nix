# Exports the SAS HBA's state to Prometheus through node_exporter's textfile
# collector. The chip temperatures come from Broadcom's storcli, since the
# mpt3sas driver exposes no hwmon sensor: the card carries one SAS3008 per
# controller, each with its own ROC (RAID-on-chip) sensor, and cools
# passively. Everything else is read from the SAS transport class in sysfs:
# what each controller is and runs, how often its firmware has reset, and
# per phy the negotiated link rate and the link error counters, which is
# where a marginal cable or backplane connector shows. See
# HBATemperatureHigh in alerts/hardware.nix.
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
      description = "Sample SAS HBA metrics for Prometheus";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "1m";
        OnUnitActiveSec = "1m";
      };
    };

    services.hba-metrics = {
      description = "SAS HBA metrics for node_exporter";
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

        temperatures=$(${storcli} /call show temperature J | ${jq} -r ${lib.escapeShellArg program})
        [ -n "$temperatures" ]

        info= resets= rates= errors=
        for host in /sys/class/sas_host/host*; do
          host=''${host##*/}
          attrs=/sys/class/scsi_host/$host
          controller=$(< "$attrs/unique_id")

          info+="homelab_hba_info{controller=\"$controller\",board=\"$(< "$attrs/board_name")\",firmware=\"$(< "$attrs/version_fw")\",bios=\"$(< "$attrs/version_bios")\"} 1"$'\n'
          resets+="homelab_hba_ioc_resets_total{controller=\"$controller\"} $(< "$attrs/ioc_reset_count")"$'\n'

          for phy in /sys/class/sas_phy/phy-''${host#host}:*; do
            labels="controller=\"$controller\",phy=\"$(< "$phy/phy_identifier")\""

            # A phy with no link reports a state in place of a rate, and
            # exports as 0.
            rate=$(< "$phy/negotiated_linkrate")
            case $rate in
              *" Gbit") rate=''${rate% Gbit} ;;
              *) rate=0 ;;
            esac
            rates+="homelab_hba_phy_link_rate_gbps{$labels} $rate"$'\n'

            for type in invalid_dword running_disparity_error loss_of_dword_sync phy_reset_problem; do
              errors+="homelab_hba_phy_errors_total{$labels,type=\"$type\"} $(< "$phy/''${type}_count")"$'\n'
            done
          done
        done

        metric() {
          echo "# HELP $1 $3"
          echo "# TYPE $1 $2"
          echo "''${4%$'\n'}"
        }

        {
          metric homelab_hba_temperature_celsius gauge "Temperature of a SAS HBA controller's chip, as storcli reports it." "$temperatures"
          metric homelab_hba_info gauge "A SAS HBA controller's board and the firmware and BIOS versions it runs." "$info"
          metric homelab_hba_ioc_resets_total counter "Resets of a SAS HBA controller's firmware since the driver loaded." "$resets"
          metric homelab_hba_phy_link_rate_gbps gauge "Negotiated link rate of a SAS HBA phy, 0 with no link." "$rates"
          metric homelab_hba_phy_errors_total counter "Link errors a SAS HBA phy has counted, by type." "$errors"
        } > "$out.tmp"

        mv "$out.tmp" "$out"
      '';
    };
  };
}
