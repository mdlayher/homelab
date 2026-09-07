# Exports the state of this machine's NixOS system generations to Prometheus
# through node_exporter's textfile collector, so the server can alert when a
# machine runs a configuration that was never persisted, or one that was
# never committed. `nixos-rebuild test` activates a system without recording
# it in the system profile (a reboot silently reverts it), and `boot`
# records one the machine is not yet running; both leave the running system
# and the profile disagreeing. A `switch` from a tree with uncommitted
# changes persists like any other, and the nightly upgrade silently replaces
# it; only the revision baked into the system tells. See the
# NixOSSystemUnpersisted and NixOSSystemDirty alerts in
# nixos/servnerr-4/prometheus-alerts.nix.
{ config, lib, ... }:

let
  isHost = !config.boot.isContainer;

  # The repository revision this system was built from, as recorded by
  # common.nix: a bare commit hash from a clean tree, that hash with a
  # -dirty suffix from a tree with uncommitted changes, or "unknown".
  # Anything but a bare hash counts as dirty. Baked in at build time rather
  # than read at runtime: this unit is part of the system it describes, so
  # what it reports is the running system's provenance by construction.
  revision = toString config.system.configurationRevision;
  dirty = if builtins.match "[0-9a-f]+" revision != null then 0 else 1;

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
          # HELP nixos_system_revision The repository revision the running system was built from, as the revision label; always 1.
          # TYPE nixos_system_revision gauge
          nixos_system_revision{revision="${revision}"} 1
          # HELP nixos_system_dirty Whether the running system was built from a tree with uncommitted changes, rather than from a commit the nightly upgrade could reproduce.
          # TYPE nixos_system_dirty gauge
          nixos_system_dirty ${toString dirty}
          METRICS
          mv "$out.tmp" "$out"
        '';
      };
    };
  };
}
