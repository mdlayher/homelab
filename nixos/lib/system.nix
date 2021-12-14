{ pkgs, ... }:

let
  secrets = import ./secrets.nix;

  # Import comma with local nix-index preferred over the comma one.
  comma = import (builtins.fetchTarball
    "https://github.com/Shopify/comma/archive/60a4cf8ec5c93104d3cfb9fc5a5bac8fb18cc8e4.tar.gz") {
      inherit pkgs;
    };

in {
  boot = {
    # Explicitly enable drivetemp for SATA drive temperature reporting in hwmon.
    kernelModules = [ "drivetemp" ];
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
      bandwhich
      bc
      byobu
      comma
      dmidecode
      ethtool
      gcc
      go
      git
      gnumake
      gnupg
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

  nix = {
    # Automatic Nix GC.
    gc = {
      automatic = true;
      dates = "04:00";
      options = "--delete-older-than 30d";
    };
    extraOptions = ''
      min-free = ${toString (500 * 1024 * 1024)}
    '';

    # Automatic store optimization.
    autoOptimiseStore = true;
  };

  # Run node_exporter everywhere.
  services.prometheus.exporters.node.enable = true;

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
