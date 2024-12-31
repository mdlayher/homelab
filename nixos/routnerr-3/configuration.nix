# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{ pkgs, ... }:

let
  vars = import ./lib/vars.nix;

in
{
  imports = [
    # Hardware and base system configuration.
    ./hardware-configuration.nix
    ./lib/system.nix

    # Base router networking.
    ./networking.nix
    ./nftables.nix

    # Networking daemons.
    ./coredns.nix
    ./corerad.nix
    ./caddy.nix
  ];

  # TODO: https://github.com/NixOS/nixos-hardware/pull/673
  boot.kernelParams = [ "console=ttyS0,115200n8" ];

  # Start getty over serial console.
  systemd.services."serial-getty@ttyS0" = {
    enable = true;
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Restart = "always";
    };
  };

  system.copySystemConfiguration = true;
  system.stateVersion = "23.05";

  boot = {
    kernel = {
      sysctl = {
        # Forward on all interfaces.
        "net.ipv4.conf.all.forwarding" = true;
        "net.ipv6.conf.all.forwarding" = true;

        # By default, do not automatically configure any IPv6 addresses.
        "net.ipv6.conf.all.accept_ra" = 0;
        "net.ipv6.conf.all.autoconf" = 0;
        "net.ipv6.conf.all.use_tempaddr" = 0;

        # On wired WANs, allow IPv6 autoconfiguration and tempory address use.
        "net.ipv6.conf.wan0.accept_ra" = 2;
        "net.ipv6.conf.wan0.autoconf" = 1;
        "net.ipv6.conf.wan1.accept_ra" = 2;
        "net.ipv6.conf.wan1.autoconf" = 1;
      };
    };
  };

  # Use the systemd-boot EFI boot loader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Packages specific to this machine. The base package set is defined in
  # lib/system.nix.
  environment.systemPackages = with pkgs; [
    # Stable packages.
    bind
  ];

  services = {
    # Allow mDNS to reflect between VLANs where necessary for devices such as
    # Google Home and Chromecast.
    avahi = {
      enable = true;
      allowInterfaces = with vars.interfaces; [
        "${mgmt0.name}"
        "${lan0.name}"
        "${iot0.name}"
      ];
      ipv4 = true;
      ipv6 = true;
      reflector = true;
    };

    lldpd.enable = true;

    # Enable the OpenSSH daemon.
    openssh = {
      enable = true;
      settings = {
        PasswordAuthentication = false;
        PermitRootLogin = "no";
      };
    };

    atftpd = {
      enable = true;
      root = "/var/lib/tftp";
    };
  };
}
