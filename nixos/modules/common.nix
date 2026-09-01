# Base system configuration shared by every machine and container. Settings
# which only make sense on a physical machine are gated on !boot.isContainer.
{
  config,
  inputs,
  inventory,
  lib,
  pkgs,
  ...
}:

let
  isHost = !config.boot.isContainer;

  # The primary administrative user on machines.
  user = config.homelab.user;

  # Dotfiles from nixos/dotfiles packaged into fish's vendor directories,
  # which fish searches from the system profile for every user.
  dotfiles = pkgs.runCommand "dotfiles" { } ''
    install -Dm444 -t $out/share/fish/vendor_conf.d ${../dotfiles/fish/conf.d}/*.fish
    install -Dm444 -t $out/share/fish/vendor_functions.d ${../dotfiles/fish/functions}/*.fish
  '';

  users = lib.filter (u: u.isNormalUser) (lib.attrValues config.users.users);

  # The admin user's home, on machines and in containers alike.
  home = config.users.users.${user}.home;

  # The admin's FIDO2 keys, the only ones accepted for SSH from the
  # development container: each signature requires a physical touch on the
  # workstation or laptop the agent is forwarded from. One entry per
  # hardware key, so any single key can be revoked or lost safely.
  fidoKeys = [
    "sk-ecdsa-sha2-nistp256@openssh.com AAAAInNrLWVjZHNhLXNoYTItbmlzdHAyNTZAb3BlbnNzaC5jb20AAAAIbmlzdHAyNTYAAABBBFP2wHqgmf7UPkRaoCg47yjiAGYAVNggMFLsB0WMU23IYqpfa2jbKvAc5ZFWGiDNJQYpF0KbhLXK35k/apN3UKMAAAAEc3NoOg== mdlayher home yubikey"
    "sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIFlR2YATqrkugEKD0YSYQdH2wkTWao+jDw2g/v8NiJtPAAAABHNzaDo= mdlayher desk yubikey"
    "sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIE0983a+KBZlq0d/R978t3cCd19kt8y/DIDDvDr57NW5AAAABHNzaDo= mdlayher travel yubikey"
  ];

  # Relay one connection to the newest live forwarded SSH agent socket. sshd
  # drops a socket per session under ~/.ssh/agent; ssh-add exits 2 only when
  # nothing answers on the other end. Having no live socket at all is normal
  # (no SSH session around) and exits 0 so the unit doesn't report failure;
  # socat reserves nonzero exits for real relay errors.
  agentRelay = pkgs.writeShellScript "ssh-agent-relay" ''
    for sock in $(${pkgs.coreutils}/bin/ls -t ${home}/.ssh/agent/ 2>/dev/null); do
      sock=${home}/.ssh/agent/$sock
      SSH_AUTH_SOCK=$sock ${pkgs.openssh}/bin/ssh-add -l >/dev/null 2>&1
      if [ $? -ne 2 ]; then
        exec ${pkgs.socat}/bin/socat STDIO "UNIX-CONNECT:$sock"
      fi
    done
    echo "no live agent socket, dropping connection" >&2
    exit 0
  '';
in
{
  options.homelab.user = lib.mkOption {
    type = lib.types.str;
    default = "mdlayher";
    description = "Name of the primary administrative user on machines.";
  };

  config = {
    boot = lib.mkIf isHost {
      # Explicitly enable drivetemp for SATA drive temperature reporting in hwmon.
      kernelModules = [ "drivetemp" ];

      # 2026 LTS kernel.
      kernelPackages = pkgs.linuxPackages_6_18;

      # systemd-based initrd.
      initrd.systemd.enable = true;

      # Keep /boot bounded; nightly upgrades produce a generation a day.
      loader.systemd-boot.configurationLimit = 10;
    };

    # Console configuration.
    console = {
      font = "Lat2-Terminus16";
      keyMap = "us";
    };

    # Locale and time.
    i18n.defaultLocale = "en_US.UTF-8";
    time.timeZone = "America/Detroit";

    environment = {
      # Git configuration from nixos/dotfiles as the system-wide defaults;
      # per-user configuration still overrides.
      etc = {
        gitconfig.source = ../dotfiles/git/gitconfig;
        gitignore.source = ../dotfiles/git/gitignore;
        "git-allowed-signers".source = ../dotfiles/git/allowed_signers;

        # Keys accepted for SSH from the development container (sshd Match
        # below, machines only) and for sudo everywhere (pam_rssh below);
        # see fidoKeys above.
        "ssh/${user}_fido_keys" = {
          text = lib.concatLines fidoKeys;
          mode = "0444";
        };
      };

      # terminfo for terminals which SSH in (e.g. xterm-ghostty).
      enableAllTerminfo = true;

      # Put ~/bin in PATH, where `go install` also lands with GOPATH at home.
      homeBinInPath = true;
      variables = {
        EDITOR = "nano";
        GOPATH = "$HOME";
      };

      # Packages which should be installed everywhere.
      systemPackages = with pkgs; [
        dotfiles

        age
        atuin
        bashInteractive
        bc
        bind
        bintools-unwrapped
        btop
        byobu
        comma
        curl
        dmidecode
        ethtool
        fastfetch
        file
        fio
        fish
        fwupd
        gcc
        git
        gnumake
        gptfdisk
        htop
        iftop
        iotop
        iperf3
        jq
        killall
        lm_sensors
        lshw
        lsof
        lsscsi
        magic-wormhole
        minicom
        mkpasswd
        mtr
        nano
        ndisc6
        nixfmt
        nmap
        nmon
        nvme-cli
        pciutils
        pkg-config
        pv
        ripgrep
        smartmontools
        sops
        sysstat
        tcpdump
        tmux
        tree
        unixtools.xxd
        unzip
        usbutils
        wget
        xterm

        # Unstable packages.
        unstable.go
      ];
    };

    # Enable firmware updates when possible.
    hardware.enableRedistributableFirmware = lib.mkIf isHost true;

    nix = {
      settings.experimental-features = [
        "nix-command"
        "flakes"
      ];
    }
    // lib.optionalAttrs isHost {
      # Flakes only: no channels. Pin the nixpkgs registry entry and NIX_PATH to
      # the flake input so `nix shell nixpkgs#foo`, `nix-shell -p foo`, and comma
      # all use the same nixpkgs as the running system.
      channel.enable = false;
      registry.nixpkgs.flake = inputs.nixpkgs;
      nixPath = [ "nixpkgs=flake:nixpkgs" ];

      # Automatic Nix GC.
      gc = {
        automatic = true;
        dates = "04:00";
        options = "--delete-older-than 7d";
      };

      settings.min-free = 500 * 1024 * 1024;

      # Automatic store optimization, after GC.
      optimise = {
        automatic = true;
        dates = [ "04:30" ];
      };
    };

    # Programs installed everywhere. Login shells are bash so that tools which
    # pipe POSIX scripts into a login shell over SSH (VS Code Remote-SSH, Claude
    # Code's Bash tool) work; interactive sessions hand over to fish.
    programs = {
      fish = {
        enable = true;
        interactiveShellInit = ''
          # No greeting.
          set -g fish_greeting

          # Shell history via atuin, with the up arrow left to fish.
          ${pkgs.atuin}/bin/atuin init fish --disable-up-arrow | source
        '';
      };
      bash = {
        completion.enable = true;
        # Long-lived sessions not descended from an SSH login (e.g. herdr
        # panes) reach a forwarded SSH agent through the relay socket below,
        # e.g. for git commit signing.
        loginShellInit = ''
          if [[ -z "$SSH_AUTH_SOCK" ]]; then
            export SSH_AUTH_SOCK="$HOME/.ssh/agent.sock"
          fi
        '';
        interactiveShellInit = ''
          if [[ $(${pkgs.procps}/bin/ps --no-header --pid=$PPID --format=comm) != "fish" && -z ''${BASH_EXECUTION_STRING} ]]; then
            shopt -q login_shell && LOGIN_OPTION='--login' || LOGIN_OPTION=""
            exec ${pkgs.fish}/bin/fish $LOGIN_OPTION
          fi
        '';
      };
      nano.enable = true;
    };

    # sudo authenticates against the forwarded SSH agent's FIDO2 keys in
    # place of a password: every sudo costs a YubiKey touch, on machines and
    # inside dev containers alike, including sessions reusing an open
    # ControlMaster socket. With no agent forwarded, PAM falls through to
    # the password as before.
    security.pam = {
      rssh = {
        enable = true;
        settings = {
          auth_key_file = "/etc/ssh/${user}_fido_keys";
          # Prompt when waiting for a touch instead of pausing silently.
          cue = true;
        };
      };
      services.sudo.rssh = true;
    };
    # On machines, cache sudo authentication briefly across sessions so a
    # deploy's back-to-back remote sudo commands cost one touch, not one
    # each (they arrive as separate TTY-less SSH sessions, which the
    # default per-TTY cache cannot span). Containers keep per-invocation
    # touches: agents share the admin's user there, and the cache window
    # would be theirs too. SSH_AUTH_SOCK survives sudo via the rssh module's
    # own env_keep.
    security.sudo.extraConfig = lib.optionalString isHost ''
      Defaults timestamp_type=global, timestamp_timeout=2
    '';

    services = {
      # SSH keys only, wherever sshd is enabled, and never as root: deploys log
      # in as the admin user and escalate with sudo.
      openssh.settings = {
        PasswordAuthentication = false;
        KbdInteractiveAuthentication = false;
        PermitRootLogin = "no";
      };

      # SSH from the development container accepts only the admin's FIDO2
      # key. Its signatures happen on the workstation the agent is forwarded
      # from and each demands a physical YubiKey touch, so an unattended
      # agent holding the forwarded socket cannot authenticate — an
      # unexpected blink on the desk is a login to decline. Every other
      # source keeps the regular key file. The addresses are the container's
      # tailnet IPs, its only route to the machines.
      openssh.extraConfig = lib.mkIf isHost ''
        Match User ${user} Address ${inventory.tailnetHosts.linuxdev.ipv4},${inventory.tailnetHosts.linuxdev.ipv6}
          AuthorizedKeysFile /etc/ssh/${user}_fido_keys
      '';

      prometheus.exporters = {
        node = {
          enable = true;
          enabledCollectors = [
            "ethtool"
            "systemd"
          ];
          # Containers run a firewall; machines don't.
          openFirewall = !isHost;
        };

        # Disk health; alerts are raised by Prometheus on the server.
        smartctl.enable = isHost;
      };

      fstrim.enable = isHost;
      fwupd.enable = isHost;

      # Monitor disks and run SMART self-tests. Alerting happens through the
      # smartctl exporter rather than smartd's own notifications.
      smartd = {
        enable = isHost;
        notifications = {
          mail.enable = false;
          wall.enable = false;
        };
      };
    };

    system = {
      # Nightly rebuild from the flake published on GitHub. Upgrades happen when
      # flake.lock is bumped on main; see .github/workflows/update-flake-lock.yml.
      autoUpgrade = lib.mkIf isHost {
        enable = true;
        flake = "github:mdlayher/homelab";
      };

      # Record the repository revision which produced this system, so update
      # notifications can link to the commit. Dirty local builds have no
      # revision and are announced without a link.
      configurationRevision = inputs.self.rev or null;
    };

    systemd = {
      # Make systemd manage the hardware watchdog.
      settings.Manager.RuntimeWatchdogSec = lib.mkIf isHost "60s";

      # Standard directories in every user's home.
      tmpfiles.rules =
        lib.concatMap (
          u:
          map (dir: "d ${u.home}/${dir} 0755 ${u.name} ${u.group} -") [
            "bin"
            "src"
            "tmp"
          ]
        ) users
        # Created ahead of the agent relay socket, which would otherwise make
        # a root-owned ~/.ssh on first boot.
        ++ [ "d ${home}/.ssh 0700 ${user} users -" ];

      # Announce every newly activated system generation to Discord, so
      # nightly upgrades and manual deploys are visible without logging in.
      # The path unit fires whenever the system profile is switched; the
      # service also runs at boot to catch generations first activated by a
      # reboot, and the state file suppresses repeat announcements.
      paths.update-notify = lib.mkIf isHost {
        description = "Watch for newly activated system generations";
        wantedBy = [ "multi-user.target" ];
        pathConfig.PathChanged = "/nix/var/nix/profiles/system";
      };
      services.update-notify = lib.mkIf isHost {
        description = "Discord system update notification";
        wants = [ "network-online.target" ];
        after = [ "network-online.target" ];
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type = "oneshot";
          StateDirectory = "update-notify";
          Restart = "on-failure";
          RestartSec = "1min";
        };
        # An embed rather than plain content: Discord only renders markdown
        # links inside embeds, and the commit link is the point.
        script = ''
          current="$(readlink /nix/var/nix/profiles/system)"
          state=/var/lib/update-notify/last
          if [ -f "$state" ] && [ "$current" = "$(cat "$state")" ]; then
            exit 0
          fi

          profile=/nix/var/nix/profiles/system
          version="$(cat "$profile"/nixos-version)"
          rev="$("$profile"/sw/bin/nixos-version --json | ${pkgs.jq}/bin/jq -r '.configurationRevision // empty')"

          desc="Applied $version (''${current%-link})"
          if [ -n "$rev" ]; then
            desc="$desc · [''${rev:0:7}](https://github.com/mdlayher/homelab/commit/$rev)"
          fi

          ${pkgs.jq}/bin/jq -cn --arg title ${config.networking.hostName} --arg desc "$desc" \
            '{embeds: [{title: $title, description: $desc}]}' \
            | ${pkgs.curl}/bin/curl -sfS -m 10 -H 'Content-Type: application/json' -d @- \
                "$(cat ${config.sops.secrets."discord/webhook_url".path})"
          echo "$current" > "$state"
        '';
      };

      # A stable SSH agent path for sessions which outlive the SSH login that
      # spawned them (e.g. herdr panes): each connection is relayed to the
      # newest forwarded agent socket which still answers, so a dead SSH
      # session can never strand git signing or sudo behind a stale socket.
      sockets.ssh-agent-relay = {
        description = "SSH agent relay socket";
        wantedBy = [ "sockets.target" ];
        socketConfig = {
          ListenStream = "${home}/.ssh/agent.sock";
          Accept = true;
          SocketUser = user;
          SocketMode = "0600";
        };
      };
      services."ssh-agent-relay@" = {
        description = "SSH agent relay";
        serviceConfig = {
          User = user;
          ExecStart = agentRelay;
          StandardInput = "socket";
          StandardOutput = "socket";
          StandardError = "journal";
        };
      };
    };

    # Secrets are decrypted at activation using the machine's SSH host key.
    # Secrets shared by every machine live in nixos/secrets/common.yaml; a
    # machine with secrets of its own sets sops.defaultSopsFile.
    sops = lib.mkIf isHost {
      age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

      # Password hashes must be available before users are created.
      secrets =
        lib.genAttrs [ "users/mdlayher_password_hash" "users/root_password_hash" ] (_: {
          sopsFile = ../secrets/common.yaml;
          neededForUsers = true;
        })
        // {
          # Webhook for update-notify above.
          "discord/webhook_url".sopsFile = ../secrets/common.yaml;
        };
    };

    users = {
      # Force declarative user configuration.
      mutableUsers = false;

      # Set up the admin user's account, enable sudo and SSH login. Containers
      # define their own user.
      users = lib.mkIf isHost {
        ${user} = {
          isNormalUser = true;
          uid = 1000;
          extraGroups = [
            "dialout"
            "wheel"
          ];
          hashedPasswordFile = config.sops.secrets."users/mdlayher_password_hash".path;
          shell = pkgs.bashInteractive;

          openssh.authorizedKeys.keys = [
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIN5i5d0mRKAf02m+ju+I1KrAYw3Ny2IHXy88mgyragBN Matt Layher (mdlayher@gmail.com)"
          ];
        };

        # Set up root login for emergency console access.
        root.hashedPasswordFile = config.sops.secrets."users/root_password_hash".path;
      };
    };
  };
}
