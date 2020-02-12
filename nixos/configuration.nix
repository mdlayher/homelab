# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{ config, lib, pkgs, ... }:

let
  vars = import ./vars.nix;
  unstable = import <unstable> { };

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
    ./traefik.nix
    ./wgipamd.nix

    # Unstable modules.
    <unstable/nixos/modules/services/networking/corerad.nix>

    # Out-of-tree modules.
    ./modules/wgipamd.nix
  ];

  nixpkgs.overlays = [
    (self: super: {
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
    nixfmt
    nmap
    screenfetch
    tcpdump
    tmux
    wget
    wireguard-tools

    # Unstable packages.
    unstable.corerad
  ];

  # Automatic Nix GC.
  nix = {
    gc = {
      automatic = true;
      dates = "weekly";
    };
    extraOptions = ''
      min-free = ${toString (500 * 1024 * 1024)}
    '';
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
    fwupd.enable = true;
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
    stateVersion = "19.09"; # Did you read the comment?
  };
}
