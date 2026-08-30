# Base system configuration shared by every machine.
{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:

{
  boot = {
    # Explicitly enable drivetemp for SATA drive temperature reporting in hwmon.
    kernelModules = [ "drivetemp" ];

    # 2026 LTS kernel.
    kernelPackages = pkgs.linuxPackages_6_18;

    # systemd-based initrd.
    initrd.systemd.enable = true;
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
    # Put ~/bin in PATH.
    homeBinInPath = true;

    # Packages which should be installed on every machine.
    systemPackages = with pkgs; [
      age
      atuin
      bc
      bintools-unwrapped
      btop
      byobu
      comma
      dmidecode
      ethtool
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
      fastfetch
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
  hardware.enableRedistributableFirmware = true;

  # Keep /boot bounded; nightly upgrades produce a generation a day.
  boot.loader.systemd-boot.configurationLimit = 10;

  nix = {
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

    settings = {
      experimental-features = [
        "nix-command"
        "flakes"
      ];
      min-free = 500 * 1024 * 1024;
    };

    # Automatic store optimization, after GC.
    optimise = {
      automatic = true;
      dates = [ "04:30" ];
    };
  };

  # Programs installed on every machine.
  programs = {
    fish.enable = true;
    nano.enable = true;
  };

  # Services which run on all deployed machines.
  services = {
    fstrim.enable = true;
    fwupd.enable = true;

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
      };

      # Disk health; alerts are raised by Prometheus on servnerr-4.
      smartctl.enable = true;
    };

    # Monitor disks and run SMART self-tests. Alerting happens through the
    # smartctl exporter rather than smartd's own notifications.
    smartd = {
      enable = true;
      notifications = {
        mail.enable = false;
        wall.enable = false;
      };
    };
  };

  # Nightly rebuild from the flake published on GitHub. Upgrades happen when
  # flake.lock is bumped on main; see .github/workflows/update-flake-lock.yml.
  system.autoUpgrade = {
    enable = true;
    flake = "github:mdlayher/homelab";
  };

  # Make systemd manage the hardware watchdog.
  systemd.settings.Manager.RuntimeWatchdogSec = "60s";

  # Secrets are decrypted at activation using the machine's SSH host key.
  # Secrets shared by every machine live in nixos/secrets/common.yaml; a
  # machine with secrets of its own sets sops.defaultSopsFile.
  sops = {
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

    # Set up matt's account, enable sudo and SSH login.
    users.matt = {
      isNormalUser = true;
      uid = 1000;
      extraGroups = [
        "dialout"
        "libvirtd"
        "wheel"
      ];
      hashedPasswordFile = config.sops.secrets."users/matt_password_hash".path;
      shell = pkgs.fish;

      openssh.authorizedKeys.keys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIN5i5d0mRKAf02m+ju+I1KrAYw3Ny2IHXy88mgyragBN Matt Layher (mdlayher@gmail.com)"
      ];
    };

    # Set up root login for emergency console access.
    users.root.hashedPasswordFile = config.sops.secrets."users/root_password_hash".path;
  };
}
