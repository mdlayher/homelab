# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{ config, lib, pkgs, ... }:

let vars = import ./vars.nix;

in {
  imports = [
    # Include the results of the hardware scan.
    ./hardware-configuration.nix

    # Base router networking.
    ./networking.nix
    ./nftables.nix

    # Networking daemons.
    ./coredns.nix
    ./corerad.nix
    ./dhcpd4.nix
    ./wgipamd.nix

    # Modules which are not in nixpkgs.
    ./modules/corerad.nix
    ./modules/wgipamd.nix
  ];

  nixpkgs.overlays = [
    (self: super: {
      # Packages which are not in nixpkgs.
      corerad = super.callPackage ./pkgs/corerad.nix {
        buildGoModule = super.buildGo113Module;
      };
      wgipamd = super.callPackage ./pkgs/wgipamd.nix {
        buildGoModule = super.buildGo113Module;
      };
    })
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
    # Enable serial console support.
    kernelParams = [ "console=ttyS0,115200n8" ];
    # Use GRUB in MBR mode.
    loader.grub = {
      enable = true;
      version = 2;
      device = "/dev/sda";
    };
  };

  # Select internationalisation properties.
  i18n = {
    consoleFont = "Lat2-Terminus16";
    consoleKeyMap = "us";
    defaultLocale = "en_US.UTF-8";
  };

  # Set your time zone.
  time.timeZone = "America/Detroit";

  # List packages installed in system profile. To search, run:
  # $ nix search wget
  environment.systemPackages = with pkgs; [
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
    lm_sensors
    ndisc6
    nixfmt
    tcpdump
    tmux
    wget
    wireguard-tools
  ];

  services = {
    apcupsd = { enable = true; };

    # Enable the OpenSSH daemon.
    openssh = {
      enable = true;
      passwordAuthentication = false;
      permitRootLogin = "no";
    };

    prometheus = { exporters = { node = { enable = true; }; }; };
  };

  users.users.matt = {
    isNormalUser = true;
    uid = 1000;
    extraGroups = [ "wheel" ];

    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIN5i5d0mRKAf02m+ju+I1KrAYw3Ny2IHXy88mgyragBN Matt Layher (mdlayher@gmail.com)"
    ];
  };

  # This value determines the NixOS release with which your system is to be
  # compatible, in order to avoid breaking some software such as database
  # servers. You should change this only after NixOS release notes say you
  # should.
  system.stateVersion = "19.09"; # Did you read the comment?
}
