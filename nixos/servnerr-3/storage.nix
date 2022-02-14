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

    # Snapshot every 15 minutes.
    snapshotting = {
      type = "periodic";
      prefix = "zrepl_";
      interval = "15m";
    };

    pruning = {
      keep_sender = [
        # Keep snapshots that are not already replicated.
        {
          type = "not_replicated";
        }
        # Keep manual snapshots.
        {
          type = "regex";
          regex = "^manual_.*";
        }
        # Keep time-based bucketed snapshots.
        keepGrid
      ];
      # Keep the same automatic snapshots as source.
      keep_receiver = [ keepGrid ];
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
        # Always enable compression.
        compression = "on";

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
  sinkLocalEncrypted = (zpool:
    lib.mkMerge [
      (sinkLocal zpool)
      { recv.placeholder.encryption = "inherit"; }
    ]);

  # Generate the zrepl push job name for a target zpool.
  pushName = (zpool: "primary_to_${zpool}");

  # Generate the zrepl sink job name for a target zpool.
  sinkName = (zpool: "sink_${zpool}");

  # Keep time-based bucketed snapshots.
  keepGrid = {
    type = "grid";
    # Keep:
    # - every snapshot from the last hour
    # - every hour from the last 24 hours
    # - every day from the last 2 weeks
    # - every week from the last 2 months
    # - every month from the last 2 years
    #
    # TODO(mdlayher): verify retention after a couple weeks!
    grid = "1x1h(keep=all) | 24x1h | 14x1d | 8x7d | 24x30d";
    regex = "^zrepl_.*";
  };

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
}
