# Exports the state of this machine's NixOS system generations to Prometheus
# through node_exporter's textfile collector, so the server can alert when a
# machine runs a configuration that was never persisted. `nixos-rebuild
# test` activates a system without recording it in the system profile (a
# reboot silently reverts it), and `boot` records one the machine is not yet
# running; both leave the running system and the profile disagreeing. See
# the NixOSSystemUnpersisted alert in nixos/servnerr-4/prometheus-alerts.nix.
{ config, lib, ... }:

let
  isHost = !config.boot.isContainer;

  # Where the collector reads *.prom files from. Writers drop files in
  # atomically so a scrape never sees a partial file.
  textfileDir = "/var/lib/node-exporter/textfile";
in
{
  config = lib.mkIf isHost {
    services.prometheus.exporters.node.extraFlags = [
      "--collector.textfile.directory=${textfileDir}"
    ];

    systemd = {
      tmpfiles.rules = [ "d ${textfileDir} 0755 root root -" ];

      # Three symlinks describe the machine's state: the system profile is
      # what the bootloader and the nightly upgrade track, /run/current-system
      # is what is running, and /run/booted-system is what was running at
      # boot. Sampling them once a minute is cheaper than watching, and a
      # minute of lag is nothing next to the alert's hour.
      timers.nixos-system-metrics = {
        description = "Sample NixOS system generation state for Prometheus";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "1m";
          OnUnitActiveSec = "1m";
        };
      };
      services.nixos-system-metrics = {
        description = "NixOS system generation metrics for node_exporter";
        serviceConfig.Type = "oneshot";
        script = ''
          profile="$(readlink -f /nix/var/nix/profiles/system)"
          current="$(readlink -f /run/current-system)"
          booted="$(readlink -f /run/booted-system)"

          differs() {
            if [ "$1" != "$2" ]; then echo 1; else echo 0; fi
          }

          out=${textfileDir}/nixos-system.prom
          cat > "$out.tmp" <<METRICS
          # HELP nixos_system_unpersisted Whether the running system differs from the system profile: after nixos-rebuild test, or after boot until the reboot.
          # TYPE nixos_system_unpersisted gauge
          nixos_system_unpersisted $(differs "$current" "$profile")
          # HELP nixos_system_switched_since_boot Whether the running system differs from the one booted: a switch since boot, so kernel or initrd changes are not yet in effect.
          # TYPE nixos_system_switched_since_boot gauge
          nixos_system_switched_since_boot $(differs "$current" "$booted")
          METRICS
          mv "$out.tmp" "$out"
        '';
      };
    };
  };
}
