{ pkgs, ... }:

{
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

    # Assume all NixOS machines are headless.
    # TODO: factor out if I ever switch my desktop.
    noXlibs = true;

    # Packages which should be installed on every machine.
    systemPackages = with pkgs; [
      byobu
      dmidecode
      ethtool
      gcc
      go
      git
      htop
      iftop
      iperf3
      jq
      lm_sensors
      lshw
      ndisc6
      neofetch
      nethogs
      nixfmt
      nix-linter
      nmap
      pciutils
      tcpdump
      tmux
      usbutils
      wget
      wireguard-tools
    ];
  };

  system = {
    # Automatic upgrades.
    autoUpgrade = { enable = true; };

    # This value determines the NixOS release with which your system is to be
    # compatible, in order to avoid breaking some software such as database
    # servers. You should change this only after NixOS release notes say you
    # should.
    stateVersion = "20.03"; # Did you read the comment?
  };
}
