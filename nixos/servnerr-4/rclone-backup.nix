# Off-box backup of the server's irreplaceable data to Google Drive, through
# an rclone crypt remote so Drive holds only ciphertext. See README.md for
# the remote's layout and how to restore from it.
#
# rclone copy adds and updates files on the remote and never deletes them,
# so a file removed or truncated here survives there. Each run picks up
# where the last one stopped, which carries the first seed across Drive's
# daily upload cap: a run stopped by the cap succeeds without counting as a
# complete backup, and the next day's run continues it.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (config.homelab) textfileDir textfileWriter;
  placeholder = name: config.sops.placeholder."rclone/${name}";

  # Paths below /primary, which is also the root of the remote. The unit
  # sees only these, and the filter copies only these.
  paths = [
    "archive"
    "media/photos"
    "media/video"
    "misc"
    "text"
  ];
  filter = pkgs.writeText "rclone-backup.filter" ''
    ${lib.concatMapStrings (p: "+ /${p}/**\n") paths}- **
  '';

  backup = pkgs.writeShellApplication {
    name = "rclone-backup";
    runtimeInputs = with pkgs; [
      coreutils
      gawk
      gnugrep
      jq
      rclone
    ];
    text = ''
      # rclone saves refreshed Drive tokens into its config, so it gets a
      # writable copy in the unit's private /tmp, which is discarded when
      # the unit stops.
      config=/tmp/rclone.conf
      install -m 0600 "$CREDENTIALS_DIRECTORY/rclone.conf" "$config"
      log=/tmp/copy.log

      # Binding to 0.0.0.0 makes rclone dial over IPv4 only, which the router
      # sends out the gigabit uplink; IPv6 has only the slower one.
      backup() {
        rclone --config "$config" --cache-dir "/tmp/cache" \
          --bind 0.0.0.0 --filter-from ${filter} --use-json-log "$@" /primary backup:
      }

      write() {
        cat > "${textfileDir}/$1.tmp"
        mv "${textfileDir}/$1.tmp" "${textfileDir}/$1"
      }

      # 80 MiB/s is about two thirds of the gigabit uplink, and reaches
      # Drive's daily upload cap in about two and a half hours.
      start=$(date +%s)
      rc=0
      backup copy -v --stats 15m --bwlimit 80M --drive-stop-on-upload-limit 2>&1 \
        | tee "$log" || rc=''${PIPESTATUS[0]}
      end=$(date +%s)

      # The final stats line, which rclone prints however the run ends.
      stats=$(jq -R -c 'fromjson? | select(.stats) | .stats' "$log" | tail -n 1)
      [ -n "$stats" ] || stats='{}'
      field() { jq -r --arg k "$1" '.[$k] // 0' <<<"$stats"; }

      # rclone stops at the upload cap with exit code 7 and this message. A
      # full Drive stops it with the same code and another message, and
      # fails the unit.
      limited=0
      if [ "$rc" -eq 7 ] && jq -R -r 'fromjson? | .msg // empty' "$log" \
        | grep -q '^Received upload limit error: .*User rate limit exceeded'; then
        limited=1
      fi

      write rclone-backup.prom <<METRICS
      # HELP homelab_rclone_backup_last_run_timestamp_seconds When the last backup run ended.
      # TYPE homelab_rclone_backup_last_run_timestamp_seconds gauge
      homelab_rclone_backup_last_run_timestamp_seconds $end
      # HELP homelab_rclone_backup_last_run_duration_seconds How long the last backup run's copy took.
      # TYPE homelab_rclone_backup_last_run_duration_seconds gauge
      homelab_rclone_backup_last_run_duration_seconds $((end - start))
      # HELP homelab_rclone_backup_last_run_transferred_bytes Encrypted bytes the last backup run uploaded.
      # TYPE homelab_rclone_backup_last_run_transferred_bytes gauge
      homelab_rclone_backup_last_run_transferred_bytes $(field bytes)
      # HELP homelab_rclone_backup_last_run_transferred_files Files the last backup run uploaded.
      # TYPE homelab_rclone_backup_last_run_transferred_files gauge
      homelab_rclone_backup_last_run_transferred_files $(field transfers)
      # HELP homelab_rclone_backup_last_run_errors Errors rclone counted in the last backup run.
      # TYPE homelab_rclone_backup_last_run_errors gauge
      homelab_rclone_backup_last_run_errors $(field errors)
      # HELP homelab_rclone_backup_last_run_upload_limited Whether Drive's daily upload cap stopped the last backup run.
      # TYPE homelab_rclone_backup_last_run_upload_limited gauge
      homelab_rclone_backup_last_run_upload_limited $limited
      METRICS

      # A run stopped by the cap succeeds whatever else failed in it, such
      # as a file the unit cannot read; the first run the cap does not stop
      # fails on it.
      if [ "$limited" -eq 1 ]; then
        exit 0
      elif [ "$rc" -ne 0 ]; then
        exit "$rc"
      fi

      write rclone-backup-success.prom <<METRICS
      # HELP homelab_rclone_backup_last_success_timestamp_seconds When a backup run last copied everything.
      # TYPE homelab_rclone_backup_last_success_timestamp_seconds gauge
      homelab_rclone_backup_last_success_timestamp_seconds $end
      METRICS

      # A complete copy on a Sunday is followed by a check of the remote
      # against the server, so a file is missing only if the copy failed to
      # upload it. cryptcheck reads every file here and the header of each
      # file there.
      if [ "$(date +%u)" -ne 7 ]; then
        exit 0
      fi

      combined=/tmp/check.txt
      touch "$combined"
      crc=0
      backup cryptcheck --one-way --combined "$combined" 2>&1 || crc=$?

      # Lines start with + for a file missing on the remote, * for one that
      # differs, ! for one which could not be checked and = for a match.
      read -r missing differ error match < <(awk '
        { n[$1]++ }
        END { print n["+"] + 0, n["*"] + 0, n["!"] + 0, n["="] + 0 }
      ' "$combined")

      # cryptcheck fails on any mismatch, which the metrics report; a
      # failure without one is the check itself failing.
      if [ "$crc" -ne 0 ] && [ $((missing + differ + error)) -eq 0 ]; then
        exit "$crc"
      fi

      write rclone-backup-check.prom <<METRICS
      # HELP homelab_rclone_backup_check_timestamp_seconds When the remote was last checked against the server.
      # TYPE homelab_rclone_backup_check_timestamp_seconds gauge
      homelab_rclone_backup_check_timestamp_seconds $(date +%s)
      # HELP homelab_rclone_backup_check_mismatches Files the last check found missing on the remote, differing, or impossible to check, by kind.
      # TYPE homelab_rclone_backup_check_mismatches gauge
      homelab_rclone_backup_check_mismatches{kind="missing"} $missing
      homelab_rclone_backup_check_mismatches{kind="differ"} $differ
      homelab_rclone_backup_check_mismatches{kind="error"} $error
      # HELP homelab_rclone_backup_check_matches Files the last check found identical on the remote.
      # TYPE homelab_rclone_backup_check_matches gauge
      homelab_rclone_backup_check_matches $match
      METRICS
    '';
  };
in
{
  sops = {
    secrets = lib.genAttrs [
      "rclone/drive_client_id"
      "rclone/drive_client_secret"
      "rclone/drive_token"
      "rclone/crypt_password"
      "rclone/crypt_salt"
    ] (_: { });

    # The crypt remote stores its files under the homelab-backup folder of
    # the drive remote. The drive.file scope limits the token to files this
    # OAuth client created, so the folder must be created by rclone. The
    # crypt password and salt are in rclone's obscured form.
    templates."rclone-backup.conf".content = ''
      [gdrive]
      type = drive
      client_id = ${placeholder "drive_client_id"}
      client_secret = ${placeholder "drive_client_secret"}
      scope = drive.file
      token = ${placeholder "drive_token"}

      [backup]
      type = crypt
      remote = gdrive:homelab-backup
      password = ${placeholder "crypt_password"}
      password2 = ${placeholder "crypt_salt"}
    '';
  };

  # For restores; see README.md.
  environment.systemPackages = [ pkgs.rclone ];

  systemd = {
    timers.rclone-backup = {
      description = "Back up irreplaceable data to Google Drive";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "01:00";
        Persistent = true;
      };
    };

    # rclone logs each file it uploads and its stats to the journal, as
    # JSON.
    services.rclone-backup = {
      description = "Back up irreplaceable data to Google Drive";
      after = [
        "network-online.target"
        "sops-install-secrets.service"
      ];
      wants = [ "network-online.target" ];
      # A deploy during a run leaves it to finish; the next run takes the
      # new configuration.
      restartIfChanged = false;
      serviceConfig = textfileWriter // {
        Type = "oneshot";
        ExecStart = lib.getExe backup;
        # systemd reads the root-owned config on the unit's behalf.
        LoadCredential = [ "rclone.conf:${config.sops.templates."rclone-backup.conf".path}" ];
        Nice = 19;
        IOSchedulingClass = "idle";

        # The unit runs in an empty root holding only the store, the paths
        # it backs up, the resolver config, the local time zone and the
        # textfile directory. It reads the backed up files as an
        # unprivileged user, so they must stay world-readable; one that is
        # not fails the run.
        RuntimeDirectory = "rclone-backup";
        RootDirectory = "/run/rclone-backup";
        MountAPIVFS = true;
        BindReadOnlyPaths = [
          builtins.storeDir
          # With no nsswitch.conf in the root, Go resolves names itself
          # through the resolver in this file.
          "/run/systemd/resolve/stub-resolv.conf:/etc/resolv.conf"
          "/etc/localtime"
        ]
        ++ map (p: "/primary/${p}") paths;
        BindPaths = [ textfileDir ];
        # Go reads its CA bundle from this file.
        Environment = [ "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt" ];
        CapabilityBoundingSet = "";
        ProtectHome = true;
        NoNewPrivileges = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectProc = "invisible";
        ProtectClock = true;
        ProtectHostname = true;
        ProtectControlGroups = true;
        ProtectKernelLogs = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
        ];
        SystemCallArchitectures = "native";
        SystemCallFilter = [ "@system-service" ];
      };
    };
  };
}
