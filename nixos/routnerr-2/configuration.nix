# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{ config, lib, pkgs, ... }:

let
  vars = import ./vars.nix;
  unstable = import <unstable> { };

in {
  imports = [
    # Hardware configuration and quirks.
    <nixos-hardware/pcengines/apu>
    ./hardware-configuration.nix

    # Base router networking.
    ./networking.nix
    ./nftables.nix

    # Networking daemons.
    ./coredns.nix
    ./corerad.nix
    ./dhcpd4.nix
    ./dhcpd6.nix
    ./traefik.nix
    ./wgipamd.nix

    # Out-of-tree modules.
    ./lib/modules/wgipamd.nix
  ];

  # Use the GRUB 2 boot loader with MBR.
  boot = {
    kernel = {
      sysctl = {
        # Forward on all interfaces.
        "net.ipv4.conf.all.forwarding" = true;
        "net.ipv6.conf.all.forwarding" = true;

        # By default, not automatically configure any IPv6 addresses.
        "net.ipv6.conf.all.accept_ra" = 0;
        "net.ipv6.conf.all.autoconf" = 0;
        "net.ipv6.conf.all.use_tempaddr" = 0;

        # On WAN, allow IPv6 autoconfiguration and tempory address use.
        "net.ipv6.conf.${vars.interfaces.wan0.name}.accept_ra" = 2;
        "net.ipv6.conf.${vars.interfaces.wan0.name}.autoconf" = 1;
        "net.ipv6.conf.${vars.interfaces.wan0.name}.use_tempaddr" = 1;
      };
    };
    # Use GRUB in MBR mode.
    loader.grub = {
      enable = true;
      version = 2;
      device = "/dev/sda";
    };
  };

  # Console and i18n properties.
  console = {
    font = "Lat2-Terminus16";
    keyMap = "us";
  };

  i18n.defaultLocale = "en_US.UTF-8";

  # Set your time zone.
  time.timeZone = "America/Detroit";

  environment = {
    # Put ~/bin in PATH.
    homeBinInPath = true;

    # This is a headless machine.
    noXlibs = true;

    # List packages installed in system profile. To search, run:
    # $ nix search wget
    systemPackages = with pkgs; [
      # Stable packages.
      bind
      byobu
      cbfstool
      dmidecode
      ethtool
      flashrom
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
      nmap
      pciutils
      tcpdump
      tmux
      usbutils
      wget
      wireguard-tools

      # Unstable packages.
      unstable.corerad
    ];
  };

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

  services = {
    # Allow mDNS to reflect between VLANs where necessary for devices such as
    # Google Home and Chromecast.
    avahi = {
      enable = true;
      interfaces =
        [ "${vars.interfaces.lan0.name}" "${vars.interfaces.iot0.name}" ];
      ipv4 = true;
      ipv6 = true;
      reflector = true;
    };

    apcupsd.enable = true;

    lldpd.enable = true;

    # Enable the OpenSSH daemon.
    openssh = {
      enable = true;
      passwordAuthentication = false;
      permitRootLogin = "no";
    };

    prometheus = { exporters = { node = { enable = true; }; }; };

    tftpd = {
      enable = true;
      path = "/var/lib/tftp";
    };
  };

  users.users.matt = {
    isNormalUser = true;
    uid = 1000;
    extraGroups = [ "wheel" ];

    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIN5i5d0mRKAf02m+ju+I1KrAYw3Ny2IHXy88mgyragBN Matt Layher (mdlayher@gmail.com)"
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
