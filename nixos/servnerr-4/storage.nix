{ config, lib, ... }:

let

  # Creates snapshots of zpool source using a zrepl snap job.
  snap = (
    source: {
      name = "snap_${source}";
      type = "snap";

      # Snapshot the entire pool every 15 minutes.
      filesystems."${source}<" = true;
      snapshotting = {
        type = "periodic";
        prefix = "zrepl_";
        interval = "15m";
      };

      pruning.keep = keepSnaps;
    }
  );

  # Advertises zpool source as a zrepl source job for target.
  sourceLocal = (
    source:
    (target: {
      name = "source_${source}_${target}";
      type = "source";

      # Export everything, do not snapshot in this job.
      filesystems."${source}<" = true;
      snapshotting.type = "manual";

      serve = {
        type = "local";
        listener_name = "source_${source}_${target}";
      };
    })
  );

  # Templates out a zrepl pull job which replicates from zpool source into
  # target.
  _pullLocal = (
    source:
    (
      target:
      (root_fs: {
        name = "pull_${source}_${target}";
        type = "pull";

        # Replicate all of the source zpool into target.
        root_fs = root_fs;
        interval = "15m";

        connect = {
          type = "local";
          listener_name = "source_${source}_${target}";
          # Assumes only a single client (localhost).
          client_identity = "local";
        };

        recv = {
          # Necessary for encrypted destination with unencrypted source.
          placeholder.encryption = "inherit";

          properties = {
            # Inherit any encryption properties.
            "inherit" = [
              "encryption"
              "keyformat"
              "keylocation"
            ];

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
        };

        # Allow replication concurrency. This should generally speed up blocking
        # zfs operations but may negatively impact file I/O. Tune as needed.
        replication.concurrency.steps = 4;

        pruning = {
          keep_sender = [
            {
              # The source job handles pruning.
              type = "regex";
              regex = ".*";
            }
          ];
          # Keep the same automatic snapshots as source.
          keep_receiver = keepSnaps;
        };
      })
    )
  );

  # Creates a zrepl pull job which replicates from zpool source into target
  # directly.
  pullLocal = (source: (target: (_pullLocal source target target)));

  # Creates a zrepl pull job which replicates from zpool source into an
  # encrypted top-level dataset in target.
  pullLocalEncrypted = (source: (target: (_pullLocal source target "${target}/encrypted")));

  # Rules to keep zrepl snapshots.
  keepSnaps = [
    # Keep manual snapshots.
    {
      type = "regex";
      regex = "^manual_.*";
    }
    # Keep time-based bucketed snapshots.
    {
      type = "grid";
      # Keep:
      # - every snapshot from the last hour
      # - every hour from the last 24 hours
      # - every day from the last 2 weeks
      # - every week from the last 2 months
      # - every month from the last 2 years
      grid = "1x1h(keep=all) | 24x1h | 14x1d | 8x7d | 24x30d";
      regex = "^zrepl_.*";
    }
  ];

in
{
  # primary zpool mounts.
  fileSystems =
    lib.genAttrs
      [
        "/primary"
        "/primary/archive"
        "/primary/media"
        "/primary/misc"
        "/primary/text"
        "/primary/vm"
      ]
      (device: {
        # The device has the leading / removed.
        device = builtins.substring 1 255 device;
        fsType = "zfs";
      });

  boot.zfs = {
    # Don't mount secondary, just import it on boot.
    extraPools = [ "secondary" ];
    # The root filesystem is ext4; never force-import pools.
    forceImportRoot = false;
  };

  nixpkgs = {
    # Only allow certain unfree packages.
    config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [ "tarsnap" ];
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
      autoScrub = {
        enable = true;
        interval = "monthly";
      };

      # ZED configuration. Secret settings are injected via the sops template
      # below rather than here, so they don't end up in the Nix store.
      zed = {
        enableMail = false;
        settings = {
          # Event notifications go to Discord; see sops.templates."zed.rc".

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
        global.monitoring = [
          {
            type = "prometheus";
            listen = ":9811";
          }
        ];
        jobs = [
          # Take snapshots of primary and advertise it as a source for each
          # fan-out pull job. Notably a source per pull job is necessary to
          # maintain incremental replication, see:
          # https://zrepl.github.io/quickstart/fan_out_replication.html.
          (snap "primary")
          (sourceLocal "primary" "secondary")
          (sourceLocal "primary" "backup0")
          (sourceLocal "primary" "backup1")

          # Pull primary into backup pools:
          # -  hot: pull into secondary
          # - cold: pull into backup{0,1} (if available)
          (pullLocal "primary" "secondary")
          (pullLocalEncrypted "primary" "backup0")
          (pullLocalEncrypted "primary" "backup1")
        ];
      };
    };
  };

  # ZED reads notification secrets from zed.rc, which has no separate secrets
  # file mechanism. Render the module-generated zed.rc plus the secret webhook
  # into a sops template and point /etc/zfs/zed.d/zed.rc at it.
  #
  # ZED has no Discord backend, but Discord webhooks accept Slack-format
  # payloads at "<webhook_url>/slack", which is what the stored URL includes.
  sops = {
    secrets."zfs/discord_webhook_url" = { };
    templates."zed.rc" = {
      content = ''
        ${config.environment.etc."zfs/zed.d/zed.rc".text}
        ZED_SLACK_WEBHOOK_URL="${config.sops.placeholder."zfs/discord_webhook_url"}"
      '';
      restartUnits = [ "zfs-zed.service" ];
    };
  };
  environment.etc."zfs/zed.d/zed.rc".source = lib.mkForce config.sops.templates."zed.rc".path;
}
