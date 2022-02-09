{ lib, pkgs, ... }:

let
  secrets = import ./lib/secrets.nix;

in {
  # Only allow certain unfree packages.
  nixpkgs.config.allowUnfreePredicate = pkg:
    builtins.elem (lib.getName pkg) [ "tarsnap" ];

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
        # timestamp, verbose logging.
        flags = "-d -k -p -u -v";

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
  };
}
