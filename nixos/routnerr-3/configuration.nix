{ config, pkgs, ... }:

let
  inventory = config.homelab.inventory;
in
{
  imports = [
    # Hardware and base router networking. The shared base system lives in
    # nixos/modules/ and is imported by flake.nix.
    ./hardware-configuration.nix
    ./networking.nix
    ./nftables.nix

    # Networking daemons.
    ./coredns.nix
    ./corerad.nix
  ];

  system.stateVersion = "23.05";

  # Secrets for this machine, encrypted with sops. Edit with:
  #   sops nixos/routnerr-3/secrets.yaml
  sops.defaultSopsFile = ./secrets.yaml;

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

    # Use the systemd-boot EFI boot loader.
    loader = {
      systemd-boot.enable = true;
      efi.canTouchEfiVariables = true;
    };
  };

  # Packages specific to this machine. The base package set is defined in
  # nixos/modules/common.nix.
  environment.systemPackages = with pkgs; [
    bind
  ];

  services = {
    # Allow mDNS to reflect between VLANs where necessary for devices such as
    # Google Home and Chromecast.
    avahi = {
      enable = true;
      allowInterfaces = with inventory.interfaces; [
        mgmt0.name
        lan0.name
        iot0.name
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
