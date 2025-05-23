{ pkgs, ... }:

let
  secrets = import ./secrets.nix;
  unstable = import <nixos-unstable-small> { };

in
{
  boot = {
    # Explicitly enable drivetemp for SATA drive temperature reporting in hwmon.
    kernelModules = [ "drivetemp" ];

    # 2025 LTS kernel.
    kernelPackages = pkgs.linuxPackages_6_12;
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
      neofetch
      nixfmt-rfc-style
      nmap
      nmon
      nvme-cli
      pciutils
      pkg-config
      pv
      ripgrep
      smartmontools
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

  nix = {
    # Automatic Nix GC.
    gc = {
      automatic = true;
      dates = "04:00";
      options = "--delete-older-than 7d";
    };
    extraOptions = ''
      min-free = ${toString (500 * 1024 * 1024)}
      experimental-features = nix-command flakes
    '';

    # Automatic store optimization.
    settings.auto-optimise-store = true;
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
    prometheus.exporters.node = {
      enable = true;
      enabledCollectors = [
        "ethtool"
        "systemd"
      ];
    };
  };

  system.autoUpgrade.enable = true;

  # Make systemd manage the hardware watchdog.
  systemd.watchdog.runtimeTime = "60s";

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
        "networkmanager"
        "wheel"
      ];
      hashedPassword = secrets.users.matt_password_hash;
      shell = pkgs.fish;

      openssh.authorizedKeys.keys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIN5i5d0mRKAf02m+ju+I1KrAYw3Ny2IHXy88mgyragBN Matt Layher (mdlayher@gmail.com)"
      ];
    };

    # Set up root login for emergency console access.
    users.root.hashedPassword = secrets.users.root_password_hash;
  };
}
