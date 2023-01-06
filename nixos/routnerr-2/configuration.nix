# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{ pkgs, ... }:

let vars = import ./lib/vars.nix;

in {
  imports = [
    # Hardware and base system configuration.
    <nixos-hardware/pcengines/apu>
    ./hardware-configuration.nix
    ./lib/system.nix

    # Base router networking.
    ./networking.nix
    ./nftables.nix

    # Networking daemons.
    ./coredns.nix
    ./corerad.nix
    ./traefik.nix

    # Unstable or out-of-tree modules.
    ./lib/modules/wireguard_exporter.nix
  ];

  system.stateVersion = "22.11";

  # Overlays for unstable and out-of-tree packages.
  nixpkgs.overlays = [
    (_self: super: {
      wireguard_exporter =
        super.callPackage ./lib/pkgs/wireguard_exporter.nix { };
    })
  ];

  boot = {
    kernel = {
      sysctl = with vars.interfaces.wan0; {
        # Forward on all interfaces.
        "net.ipv4.conf.all.forwarding" = true;
        "net.ipv6.conf.all.forwarding" = true;

        # By default, not automatically configure any IPv6 addresses.
        "net.ipv6.conf.all.accept_ra" = 0;
        "net.ipv6.conf.all.autoconf" = 0;
        "net.ipv6.conf.all.use_tempaddr" = 0;

        # On WAN, allow IPv6 autoconfiguration and tempory address use.
        "net.ipv6.conf.${name}.accept_ra" = 2;
        "net.ipv6.conf.${name}.autoconf" = 1;
      };
    };

    # Use the GRUB 2 boot loader with MBR.
    loader.grub = {
      enable = true;
      version = 2;
      device = "/dev/disk/by-id/ata-INDMEM_mSATA_256GB_AA200313000000000122";
    };
  };

  # Packages specific to this machine. The base package set is defined in
  # lib/system.nix.
  environment.systemPackages = with pkgs; [
    # Stable packages.
    bind
    cbfstool
    cmatrix
    flashrom
    libmbim
    libqmi

    # Unstable and out-of-tree packages.
    wireguard_exporter
  ];

  # Use server as a remote builder.
  nix = {
    distributedBuilds = true;
    buildMachines = [{
      hostName = "servnerr-4";
      system = "x86_64-linux";
      maxJobs = 16;
      speedFactor = 4;
      supportedFeatures = [ "nixos-test" "benchmark" "big-parallel" "kvm" ];
    }];
  };

  services = {
    apcupsd.enable = true;

    # Allow mDNS to reflect between VLANs where necessary for devices such as
    # Google Home and Chromecast.
    avahi = {
      enable = true;
      interfaces = with vars.interfaces; [
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
      passwordAuthentication = false;
      permitRootLogin = "no";
    };

    atftpd = {
      enable = true;
      root = "/var/lib/tftp";
    };
  };
}
