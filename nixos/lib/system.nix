{ pkgs, ... }:

let
  secrets = import ./secrets.nix;

  # Import comma with local nix-index preferred over the comma one.
  comma = import (builtins.fetchTarball
    "https://github.com/nix-community/comma/archive/refs/tags/1.1.0.tar.gz") {
      inherit pkgs;
    };

in {
  boot = {
    # Explicitly enable drivetemp for SATA drive temperature reporting in hwmon.
    kernelModules = [ "drivetemp" ];

    # 2022 LTS kernel, expected EOL of October 2023.
    kernelPackages = pkgs.linuxPackages_5_15;
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
      bandwhich
      bc
      byobu
      comma
      dmidecode
      ethtool
      fwupd
      gcc
      go
      git
      gnumake
      htop
      iftop
      iperf3
      jq
      lm_sensors
      lshw
      lsscsi
      magic-wormhole
      minicom
      mkpasswd
      mtr
      ndisc6
      neofetch
      nethogs
      nixfmt
      nix-linter
      nmap
      nmon
      pciutils
      pkg-config
      rustup
      smartmontools
      tcpdump
      tmux
      unixtools.xxd
      unzip
      usbutils
      wget
      wireguard-tools
    ];
  };

  # Enable firmware updates when possible.
  hardware.enableRedistributableFirmware = true;

  nix = {
    # Automatic Nix GC.
    gc = {
      automatic = true;
      dates = "04:00";
      options = "--delete-older-than 7d";
    };
    extraOptions = ''
      min-free = ${toString (500 * 1024 * 1024)}
    '';

    # Automatic store optimization.
    autoOptimiseStore = true;
  };

  # Services which run on all deployed machines.
  services = {
    fstrim.enable = true;
    fwupd.enable = true;
    prometheus.exporters.node.enable = true;
  };

  system = {
    # Automatic upgrades.
    autoUpgrade.enable = true;

    # This value determines the NixOS release with which your system is to be
    # compatible, in order to avoid breaking some software such as database
    # servers. You should change this only after NixOS release notes say you
    # should.
    stateVersion = "20.03"; # Did you read the comment?
  };

  # Make systemd manage the hardware watchdog.
  systemd.watchdog.runtimeTime = "60s";

  users = {
    # Force declarative user configuration.
    mutableUsers = false;

    # Set up matt's account, enable sudo and SSH login.
    users.matt = {
      isNormalUser = true;
      uid = 1000;
      extraGroups = [ "dialout" "libvirtd" "networkmanager" "wheel" ];
      hashedPassword = secrets.users.matt_password_hash;

      openssh.authorizedKeys.keys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIN5i5d0mRKAf02m+ju+I1KrAYw3Ny2IHXy88mgyragBN Matt Layher (mdlayher@gmail.com)"
      ];
    };
  };
}
