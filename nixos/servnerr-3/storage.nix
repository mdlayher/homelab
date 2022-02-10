{ lib, pkgs, ... }:

let
  secrets = import ./lib/secrets.nix;

  # Make a local zrepl push job from primary to the target zpool.
  pushLocal = (zpool: {
    name = pushName zpool;
    type = "push";

    # Replicate all of primary locally.
    filesystems."primary<" = true;
    connect = {
      type = "local";
      listener_name = sinkName zpool;
      client_identity = "local";
    };

    # Let zfs-auto-snapshot manage the snapshotting.
    snapshotting.type = "manual";
    pruning = {
      # Keep all primary snapshots, zfs-auto-snapshot manages them.
      keep_sender = [{
        type = "regex";
        regex = ".*";
      }];
      # Keep the last few snapshots for each dataset for disaster recovery.
      keep_receiver = [{
        type = "last_n";
        # 6 ZFS datasets, 8 snapshots each.
        count = 48;
      }];
    };
  });

  # Make a local zrepl sink job to the target zpool.
  sinkLocal = (zpool: {
    name = sinkName zpool;
    type = "sink";
    root_fs = "${zpool}";
    recv.properties = {
      # Inherit any encryption properties.
      "inherit" = [ "encryption" "keyformat" "keylocation" ];

      override = {
        # Do not mount sink pools.
        mountpoint = "none";

        # Do not auto-snapshot sink pools.
        "com.sun:auto-snapshot" = false;
        "com.sun:auto-snapshot:frequent" = false;
        "com.sun:auto-snapshot:hourly" = false;
        "com.sun:auto-snapshot:daily" = false;
        "com.sun:auto-snapshot:weekly" = false;
        "com.sun:auto-snapshot:monthly" = false;
      };
    };
    serve = {
      type = "local";
      listener_name = "sink_${zpool}";
    };
  });

  # Make a local zrepl encrypted sink job to the target zpool.
  #
  # TODO(mdlayher): unconditionally set this in sinkLocal anyway?
  sinkLocalEncrypted = (zpool: lib.mkMerge [(sinkLocal zpool) {
    recv.placeholder.encryption = "inherit";
  }]);

  # Generate the zrepl push job name for a target zpool.
  pushName = (zpool: "primary_to_${zpool}");

  # Generate the zrepl sink job name for a target zpool.
  sinkName = (zpool: "sink_${zpool}");

in {
  # ZFS filesystem mounts.
  #
  # The secondary backup pool is not mounted because we can zfs send without
  # doing so.
  fileSystems = {
    # primary ZFS pool.
    "/primary" = {
      device = "primary";
      fsType = "zfs";
    };

    "/primary/vm" = {
      device = "primary/vm";
      fsType = "zfs";
    };

    "/primary/misc" = {
      device = "primary/misc";
      fsType = "zfs";
    };

    "/primary/media" = {
      device = "primary/media";
      fsType = "zfs";
    };

    "/primary/archive" = {
      device = "primary/archive";
      fsType = "zfs";
    };

    "/primary/text" = {
      device = "primary/text";
      fsType = "zfs";
    };
  };

  nixpkgs = {
    # Only allow certain unfree packages.
    config.allowUnfreePredicate = pkg:
      builtins.elem (lib.getName pkg) [ "tarsnap" ];

    # Overlays for unstable and out-of-tree packages.
    overlays = [
      (_self: super: {
        # We want to use the latest zrepl.
        zrepl =
          super.callPackage <nixos-unstable-small/pkgs/tools/backup/zrepl> { };
      })
    ];
  };

  services = {
    # Enable tarsnap backups.
    tarsnap = {
      enable = true;

      archives.archive = {
        directories = [ "/primary/archive" ];
        verbose = true;
      };
    };

    # ZFS configuration.
    #
    # TODO(mdlayher): sharenfs integration?
    zfs = {
      # Scrub all pools regularly.
      autoScrub.enable = true;

      # Roll up snapshots for long periods of time, we have storage to burn.
      autoSnapshot = {
        enable = true;
        # Debug output, keep zero-sized snapshots, parallel snapshots, UTC
        # timestamp, verbose logging. Only snapshot primary.
        flags = "-d -k -p -u -v -P primary";

        # High frequency snapshots. For quickly rolling back unintended changes,
        # so we don't keep very many.
        #
        # Every 15 minutes for 1 hour.
        frequent = 4;
        # Every hour for 4 hours.
        hourly = 4;

        # Beyond this point, retain more snapshots for long-term archival.
        #
        # Every day for 2 weeks.
        daily = 14;
        # Every week for 2 months.
        weekly = 8;
        # Every month for 2 years.
        monthly = 24;
      };

      # ZED configuration.
      zed = {
        enableMail = false;
        settings = with secrets.zfs; {
          # Send event notifications via Pushbullet.
          ZED_PUSHBULLET_ACCESS_TOKEN = pushbullet.access_token;

          # Send event notifications via Pushover.
          #
          # TODO(mdlayher): it seems NixOS 21.11 ZFS does not support pushover
          # yet; we'll use pushbullet for now and reevaluate later.
          # ZED_PUSHOVER_TOKEN = pushover.token;
          # ZED_PUSHOVER_USER = pushover.user_key;

          # Verify integrity via scrub after resilver.
          ZED_SCRUB_AFTER_RESILVER = true;

          # More verbose reporting.
          ZED_NOTIFY_VERBOSE = true;
          ZED_DEBUG_LOG = "/var/log/zed.log";
        };
      };
    };

    # Replicate ZFS pools using zrepl.
    zrepl = {
      enable = true;
      settings = {
        global.monitoring = [{
          type = "prometheus";
          listen = ":9811";
        }];
        jobs = [
          # Replicate from primary pool to sinks.
          (pushLocal "secondary")
          (pushLocal "backup0")
          (pushLocal "backup1")

          # Local sink jobs for backups.
          (sinkLocal "secondary")
          (sinkLocalEncrypted "backup0")
          (sinkLocalEncrypted "backup1")
        ];
      };
    };
  };

  # Manual systemd unit and timer to trigger zrepl jobs. We use
  # zfs-auto-snapshot integrated into NixOS instead of zrepl's built-in
  # automatic snapshotting, so we have to signal replication manually.
  #
  # TODO(mdlayher): push upstream into services.zrepl configuration.
  systemd = {
    services.zrepl-signal-jobs = {
      serviceConfig.Type = "oneshot";
      path = with pkgs; [ zrepl ];
      script = ''
        zrepl signal wakeup ${pushName "secondary"}
        # zrepl signal wakeup ${pushName "backup0"}
        # zrepl signal wakeup ${pushName "backup1"}
      '';
    };
    timers.zrepl-signal-jobs = {
      wantedBy = [ "timers.target" ];
      partOf = [ "zrepl-signal-jobs.service" ];
      timerConfig = {
        OnCalendar = "hourly";
        Unit = "zrepl-signal-jobs.service";
      };
    };
  };
}
