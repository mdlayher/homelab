# Storage on the Linux machines: drives, ZFS pools, replication, and
# filesystem usage.
{
  exploreURL,
  raw,
  excludedInstances,
  withDrive,
  driveDevice,
  withDriveByHost,
  ...
}:

{
  name = "storage";
  rules = [
    # SATA drives through the drivetemp driver. Their self-reported
    # limits disagree wildly between models, so one threshold for all.
    {
      alert = "DriveTemperatureHigh";
      expr = ''
        node_hwmon_temp_celsius{instance!~${excludedInstances}}
          * on (instance, chip) group_left (chip_name)
        node_hwmon_chip_names{chip_name="drivetemp"}
          > 50
      '';
      for = "15m";
      annotations.summary = "Drive {{ $labels.chip }} on {{ $labels.instance }} has been at {{ $value }} °C for 15 minutes.";
    }
    {
      alert = "FilesystemUsageHigh";
      expr = ''(1 - node_filesystem_free_bytes{fstype=~"ext4|vfat"} / node_filesystem_size_bytes) > 0.75'';
      for = "1m";
      annotations.summary = "Disk usage on {{ $labels.instance }}:{{ $labels.mountpoint }} ({{ $labels.device }}) exceeds 75%.";
    }
    # NVMe wear estimate: 100% is the rated endurance, and the value may
    # keep counting past it. 80% leaves months of lead time at current
    # write rates.
    {
      alert = "NVMeWearHigh";
      expr = withDrive "smartctl_device_percentage_used >= 80";
      for = "1h";
      annotations.summary = "NVMe ${driveDevice} ({{ $labels.model_name }}, {{ $labels.serial_number }}) on {{ $labels.instance }} has used {{ $value }}% of its rated write endurance.";
    }
    # The drive's own warning threshold (WCTEMP), which the NVMe
    # specification requires every controller to report.
    {
      alert = "NVMeTemperatureHigh";
      expr = ''
        node_hwmon_temp_celsius{instance!~${excludedInstances},chip=~"nvme_.*"}
          >= on (instance, chip, sensor)
        (node_hwmon_temp_max_celsius > 0)
      '';
      for = "5m";
      annotations.summary = "NVMe drive {{ $labels.chip }} on {{ $labels.instance }} is at {{ $value }} °C, at or above its warning threshold.";
    }
    {
      alert = "SMARTCriticalWarning";
      expr = withDrive "smartctl_device_critical_warning > 0";
      for = "5m";
      annotations.summary = "NVMe ${driveDevice} ({{ $labels.model_name }}, {{ $labels.serial_number }}) on {{ $labels.instance }} reports a critical warning.";
    }
    # Early warning ahead of SMARTCriticalWarning and SMARTStatusFailed:
    # a drive's own SMART verdict flips (and can flap) only once the
    # drive declares failure, while ATA error log entries and NVMe media
    # errors appear earlier and only ever grow. Every healthy drive holds
    # zero of both; NVMe num_err_log_entries is deliberately not used,
    # since it counts thousands of informational entries on healthy
    # drives.
    {
      alert = "SMARTErrorLogGrowing";
      expr = "increase(instance_serial:smartctl_device_error_log_count:max[1d]) > 0 or increase(instance_serial:smartctl_device_media_errors:max[1d]) > 0";
      annotations.summary = "Disk ${driveDevice} ({{ $labels.model_name }}, {{ $labels.serial_number }}) on {{ $labels.instance }} logged new SMART errors in the last day.";
    }
    # Fires from a log line rather than a metric, recorded into Prometheus
    # by Loki's ruler (see nixos/servnerr-4/loki.nix) so that the drive's
    # serial can be joined in here. A broken ruler or remote write path
    # silences this rule, which is what LokiHostLogsStalled reports on.
    {
      alert = "SMARTSelfTestFailed";
      expr = withDriveByHost "host_device:smartd_selftest_errors:count15m > 0";
      annotations = {
        summary = "Disk ${driveDevice} ({{ $labels.model_name }}, {{ $labels.serial_number }}) on {{ $labels.host }} failed a SMART self-test.";
        logs_url = exploreURL ''{host="__host__", job="systemd-journal", unit="smartd.service"}'';
      };
    }
    {
      alert = "SMARTStatusFailed";
      expr = withDrive "smartctl_device_smart_status == 0";
      for = "5m";
      annotations.summary = "Disk ${driveDevice} ({{ $labels.model_name }}, {{ $labels.serial_number }}) on {{ $labels.instance }} reports SMART failure.";
    }
    # A full pool cannot receive replication streams, and zrepl's
    # receiver-side pruning only runs after a successful receive, so a
    # full replication target never frees itself. Root datasets only:
    # children share the pool's available space.
    {
      alert = "ZFSPoolOutOfSpace";
      expr = "zfs_dataset_available_bytes{name!~${raw ".*/.*"}} == 0";
      for = "5m";
      annotations.summary = "ZFS pool {{ $labels.pool }} on {{ $labels.instance }} has no available space.";
    }
    {
      alert = "ZFSPoolUnhealthy";
      # 0 is ONLINE; anything greater is DEGRADED, FAULTED, OFFLINE,
      # UNAVAIL, REMOVED, or SUSPENDED.
      expr = "zfs_pool_health > 0";
      for = "5m";
      annotations.summary = "ZFS pool {{ $labels.pool }} on {{ $labels.instance }} is unhealthy.";
    }
    # Early warning before ZFSPoolOutOfSpace: a nearly full pool still
    # has room to act. Root datasets only: children share the pool's
    # available space.
    {
      alert = "ZFSPoolUsageHigh";
      expr = "zfs_dataset_used_bytes{name!~${raw ".*/.*"}} / (zfs_dataset_used_bytes{name!~${raw ".*/.*"}} + zfs_dataset_available_bytes{name!~${raw ".*/.*"}}) > 0.9";
      for = "15m";
      annotations.summary = "ZFS pool {{ $labels.pool }} on {{ $labels.instance }} is over 90% full.";
    }
    # Errors from an attempted replication run. Unreachable targets (the
    # cold backup pools when detached) report -1 from failed planning
    # rather than a positive count, so this only fires when a run reached
    # a filesystem and failed.
    {
      alert = "ZreplReplicationFailing";
      expr = "zrepl_replication_filesystem_errors > 0";
      for = "1h";
      annotations.summary = "zrepl job {{ $labels.zrepl_job }} on {{ $labels.instance }} has had filesystem replication errors for over an hour.";
    }
    # A job which has succeeded since daemon start but then stopped. The
    # timestamp resets to zero on restart, and never-successful jobs (the
    # detached cold pools) stay at zero, so both are excluded here;
    # ZreplReplicationFailing above covers jobs failing outright.
    {
      alert = "ZreplReplicationStalled";
      expr = "(time() - zrepl_replication_last_successful) > 24*60*60 and zrepl_replication_last_successful > 0";
      annotations.summary = "zrepl job {{ $labels.zrepl_job }} on {{ $labels.instance }} has not replicated successfully in over 24 hours.";
    }
  ];
}
