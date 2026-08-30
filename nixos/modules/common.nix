# Base system configuration shared by every machine and container. Settings
# which only make sense on a physical machine are gated on !boot.isContainer.
{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:

let
  isHost = !config.boot.isContainer;

  # Dotfiles from nixos/dotfiles packaged into fish's vendor directories,
  # which fish searches from the system profile for every user.
  dotfiles = pkgs.runCommand "dotfiles" { } ''
    install -Dm444 -t $out/share/fish/vendor_conf.d ${../dotfiles/fish/conf.d}/*.fish
    install -Dm444 -t $out/share/fish/vendor_functions.d ${../dotfiles/fish/functions}/*.fish
  '';

  users = lib.filter (u: u.isNormalUser) (lib.attrValues config.users.users);
in
{
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
      interactiveShellInit = ''
        if [[ $(${pkgs.procps}/bin/ps --no-header --pid=$PPID --format=comm) != "fish" && -z ''${BASH_EXECUTION_STRING} ]]; then
          shopt -q login_shell && LOGIN_OPTION='--login' || LOGIN_OPTION=""
          exec ${pkgs.fish}/bin/fish $LOGIN_OPTION
        fi
      '';
    };
    nano.enable = true;
  };

  services = {
    # SSH keys only, wherever sshd is enabled, and never as root: deploys log
    # in as matt and escalate with sudo.
    openssh.settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
    };

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

      # Disk health; alerts are raised by Prometheus on servnerr-4.
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

  # Nightly rebuild from the flake published on GitHub. Upgrades happen when
  # flake.lock is bumped on main; see .github/workflows/update-flake-lock.yml.
  system.autoUpgrade = lib.mkIf isHost {
    enable = true;
    flake = "github:mdlayher/homelab";
  };

  systemd = {
    # Make systemd manage the hardware watchdog.
    settings.Manager.RuntimeWatchdogSec = lib.mkIf isHost "60s";

    # Standard directories in every user's home.
    tmpfiles.rules = lib.concatMap (
      u:
      map (dir: "d ${u.home}/${dir} 0755 ${u.name} ${u.group} -") [
        "bin"
        "src"
        "tmp"
      ]
    ) users;
  };

  # Secrets are decrypted at activation using the machine's SSH host key.
  # Secrets shared by every machine live in nixos/secrets/common.yaml; a
  # machine with secrets of its own sets sops.defaultSopsFile.
  sops = lib.mkIf isHost {
    age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

    # Password hashes must be available before users are created.
    secrets = lib.genAttrs [ "users/matt_password_hash" "users/root_password_hash" ] (_: {
      sopsFile = ../secrets/common.yaml;
      neededForUsers = true;
    });
  };

  users = {
    # Force declarative user configuration.
    mutableUsers = false;

    # Set up matt's account, enable sudo and SSH login. Containers define
    # their own user.
    users = lib.mkIf isHost {
      matt = {
        isNormalUser = true;
        uid = 1000;
        extraGroups = [
          "dialout"
          "libvirtd"
          "wheel"
        ];
        hashedPasswordFile = config.sops.secrets."users/matt_password_hash".path;
        shell = pkgs.bashInteractive;

        openssh.authorizedKeys.keys = [
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIN5i5d0mRKAf02m+ju+I1KrAYw3Ny2IHXy88mgyragBN Matt Layher (mdlayher@gmail.com)"
        ];
      };

      # Set up root login for emergency console access.
      root.hashedPasswordFile = config.sops.secrets."users/root_password_hash".path;
    };
  };
}
