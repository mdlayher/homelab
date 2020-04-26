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

    # Base system configuration.
    ./lib/system.nix
    ./lib/users.nix

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

  # Packages specific to this machine. The base package set is defined in
  # lib/system.nix.
  environment.systemPackages = with pkgs; [
    # Stable packages.
    bind
    cbfstool
    flashrom

    # Unstable packages.
    unstable.corerad
  ];

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

    # Use server as a remote builder.
    buildMachines = [{
      hostName = "servnerr-3";
      system = "x86_64-linux";
      maxJobs = 8;
      cores = 2;
      speedFactor = 2;
      supportedFeatures = [ "nixos-test" "benchmark" "big-parallel" "kvm" ];
    }];
    distributedBuilds = true;
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
}
