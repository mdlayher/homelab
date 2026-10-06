# The machines as systems: systemd units, NixOS upgrades and deploys,
# Prometheus targets, log shipping, and the binary cache.
{
  lib,
  logHosts,
  notifyTextfile,
  excludedInstances,
  readOnlyRootInstances,
  excludedJobsRegex,
  ...
}:

{
  name = "systems";
  rules = [
    # The complement of LokiHostLogsStalled: a shipper that is alive but
    # dropping some lines never goes fully silent, and drops are
    # permanent log loss. Steady state on every host is zero; write
    # retries that eventually succeed are fine and not counted here.
    {
      alert = "AlloyDroppingLogEntries";
      expr = "sum by (instance) (increase(loki_write_dropped_entries_total[1h])) > 0";
      annotations.summary = "Alloy on {{ $labels.instance }} dropped {{ $value | humanize }} log entries bound for Loki in the last hour.";
    }
    # Loki's ruler records per-host log line counts into Prometheus (see
    # nixos/servnerr-4/loki.nix); a host absent from the metric has
    # shipped nothing at all, even though its Alloy may still report up.
    # The lookback spans several windows because a host whose only logs
    # are an hourly timer aliases in and out of the metric on its own.
    # Every host firing at once means the ruler or its remote write path
    # is broken, not the shippers.
    {
      alert = "LokiHostLogsStalled";
      expr = lib.concatMapStringsSep " or " (
        host: ''absent_over_time(host:log_lines:count1h{host="${host}"}[6h])''
      ) logHosts;
      for = "30m";
      annotations.summary = "{{ $labels.host }} has shipped no logs to Loki for over six hours.";
    }
    # A client of the binary cache (modules/nix-cache.nix) that could not
    # use it during its nightly upgrade, recorded by Loki's ruler (see
    # loki.nix). The upgrade still succeeds by building those paths on
    # the machine, which is the work the cache exists to take off it, so
    # nothing else fails. A day's window covers the next morning.
    {
      alert = "NixCacheFailing";
      expr = "sum by (host) (sum_over_time(host:nix_cache_failures:count1m[1d])) > 0";
      annotations.summary = "{{ $labels.host }} could not use the binary cache {{ $value }} times in its upgrades over the last day, so it built those paths itself.";
    }
    # SystemdUnitFailed catches an upgrade run that fails, but a timer
    # that never runs (masked, wedged, or dropped from configuration)
    # fails nothing, and the machine silently stops tracking main. The
    # timer fires nightly, so 26 hours means a missed night; the > 0
    # guard skips a freshly booted host that has not triggered yet.
    {
      alert = "NixOSAutoUpgradeStalled";
      expr = ''(time() - node_systemd_timer_last_trigger_seconds{name="nixos-upgrade.timer"}) > 26*60*60 and node_systemd_timer_last_trigger_seconds{name="nixos-upgrade.timer"} > 0'';
      annotations.summary = "{{ $labels.instance }} has not run nixos-upgrade.timer in over 26 hours.";
    }
    # The case NixOSSystemUnpersisted cannot see: a switch from a tree
    # with uncommitted changes persists to the profile like any other,
    # and the machine then runs configuration that exists nowhere but
    # that working tree. The nightly upgrade rebuilds origin/main at
    # about 04:00 and replaces it without a word, which is how a change
    # once ran for half a day and then vanished. The metric comes from
    # the revision baked into each system; see
    # nixos/modules/system-metrics.nix.
    #
    # The wait is the tradeoff. A test or switch from a dirty tree is how
    # every change is tried during a working session and must not page,
    # but a dirty build still running twelve hours later has outlived
    # the session that made it and is heading for the nightly. A full
    # day would be quieter still and would almost never fire, since the
    # nightly resets the metric first; twelve hours leaves time to commit
    # and merge, or to expect the revert, before it does. Whether the
    # running commit matches origin/main is a question Prometheus cannot
    # answer, so this stops at dirtiness.
    {
      alert = "NixOSSystemDirty";
      expr = "nixos_system_dirty == 1";
      for = "12h";
      annotations.summary = "{{ $labels.instance }} has run a system built from uncommitted changes for over 12 hours; the nightly upgrade will replace it with main.";
    }
    # `nixos-rebuild test` activates a system without recording it in the
    # system profile, so a reboot (or the next nightly upgrade) silently
    # reverts it; `boot` records one the machine is not yet running. The
    # metric comes from each machine's textfile collector; see
    # nixos/modules/system-metrics.nix. An hour is plenty to verify a
    # test deploy and follow it with boot or switch.
    {
      alert = "NixOSSystemUnpersisted";
      expr = "nixos_system_unpersisted == 1";
      for = "1h";
      annotations.summary = "{{ $labels.instance }} has run a system other than its profile's for over an hour: a test deploy a reboot would revert, or a boot deploy awaiting one.";
    }
    # update-notify spools each announcement and returns, so a deploy no
    # longer waits on a chat webhook (see nixos/modules/common.nix). That
    # trades a slow deploy for a silent one unless something watches the
    # spool, since nothing else notices an announcement never delivered.
    # The drain rewrites its metrics file on every run, empty queue
    # included, so the file's own age catches a drainer that stopped
    # running and left the gauge frozen at its last value.
    {
      alert = "DeployNotifyUndelivered";
      expr = ''
        homelab_deploy_notify_oldest_seconds > 1800
        or time() - node_textfile_mtime_seconds{file=~${notifyTextfile}} > 1800
      '';
      for = "5m";
      annotations.summary = "{{ $labels.instance }} has not delivered a system update announcement to the ops channel in over 30 minutes.";
    }
    {
      alert = "PrometheusInstanceDown";
      expr = "up{instance!~${excludedInstances},job!~${excludedJobsRegex}} == 0";
      for = "5m";
      annotations.summary = "{{ $labels.instance }} of job {{ $labels.job }} has been down for more than 5 minutes.";
    }
    # Jobs excluded from PrometheusInstanceDown flap too often for a 5
    # minute window, but a full day of failed scrapes means the target is
    # dead rather than flaky.
    {
      alert = "PrometheusInstanceDownLong";
      expr = "avg_over_time(up{job=~${excludedJobsRegex}}[1d]) == 0";
      annotations.summary = "{{ $labels.instance }} of flaky job {{ $labels.job }} has been down for an entire day.";
    }
    # Always firing; routed to an external heartbeat so that silence from
    # this Prometheus and Alertmanager pair is itself noticed.
    {
      alert = "PrometheusWatchdog";
      expr = "vector(1)";
      annotations.summary = "Prometheus and Alertmanager on {{ $externalURL }} are alive.";
    }
    # A root filesystem meant to stay read-only, left writable after a
    # hand edit or a deploy which stopped partway.
    {
      alert = "RootFilesystemWritable";
      expr = ''node_filesystem_readonly{instance=~${readOnlyRootInstances},mountpoint="/"} == 0'';
      for = "1h";
      annotations.summary = "The root filesystem on {{ $labels.instance }} has been writable for an hour; run ro.";
    }
    # Any failed systemd unit, on any machine: this covers failed nightly
    # upgrades, sops secrets, and services which died after a switch.
    {
      alert = "SystemdUnitFailed";
      expr = ''node_systemd_unit_state{state="failed"} == 1'';
      for = "5m";
      annotations.summary = "Unit {{ $labels.name }} on {{ $labels.instance }} has failed.";
    }
    # The other half of SystemdUnitFailed, which sees only the current
    # state: a unit that crashes and comes back is invisible to it.
    #
    # NRestarts counts automatic restarts since the unit was last
    # started, so a deploy or any manual restart sets it back to zero.
    # That is why the count is read from the counter itself rather than
    # from increase() over it: increase() reads each of those resets as a
    # counter wrap and adds the pre-reset value, manufacturing restarts
    # that never happened on a day with several deploys. It fired on a
    # getty that had restarted once on 2026-09-21 for exactly that
    # reason, and extrapolation carried the total past a whole number.
    #
    # One crash overnight is not worth a notification; a third means it
    # is not recovering. The second term is what says "still": without it
    # a unit that looped once and settled keeps alerting until something
    # restarts it.
    #
    # Gettys are left out: one exits at every logout and login timeout,
    # and the KVM's USB serial gadget getty whenever the host on the other
    # end reboots or resets the link, so systemd restarting them is normal
    # use. SerialGettyInactive watches whether they are there.
    {
      alert = "SystemdUnitRestarting";
      expr = ''
        node_systemd_service_restart_total{name!~".*getty@.*"} > 2
        and increase(node_systemd_service_restart_total[30m]) > 0
      '';
      for = "10m";
      annotations.summary = "Unit {{ $labels.name }} on {{ $labels.instance }} has been restarted {{ $value | humanize }} times by systemd since it was last started.";
    }
    # A serial console's getty that was active in the last day and is not
    # now. A stopped unit that nothing wants is unloaded and its series
    # vanish rather than read inactive, so the rule compares against the
    # day's history instead of testing for zero. A machine that is down
    # is left to the target alerts. The hold covers the moment between a
    # getty exiting and systemd starting the next.
    {
      alert = "SerialGettyInactive";
      expr = ''
        max_over_time(node_systemd_unit_state{name=~"(serial|kvmd-otg)-getty@.*", state="active"}[1d]) == 1
        unless on (instance, name)
          node_systemd_unit_state{name=~"(serial|kvmd-otg)-getty@.*", state="active"} == 1
        and on (instance) up == 1
      '';
      for = "5m";
      annotations.summary = "Serial console getty {{ $labels.name }} on {{ $labels.instance }} is not active.";
    }
  ];
}
