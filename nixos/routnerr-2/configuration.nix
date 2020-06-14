# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{ pkgs, ... }:

let
  vars = import ./lib/vars.nix;
  unstable = import <nixos-unstable-small> { };

in {
  disabledModules = [
    # Replaced with unstable for additional exporters.
    "services/monitoring/prometheus/exporters.nix"
  ];

  imports = [
    # Hardware configuration and quirks.
    <nixos-hardware/pcengines/apu>
    ./hardware-configuration.nix

    # Base system configuration.
    ./lib/nix.nix
    ./lib/system.nix
    ./lib/users.nix
    ./lib/node_exporter.nix

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

    # Unstable or out-of-tree modules.
    <nixos-unstable-small/nixos/modules/services/monitoring/prometheus/exporters.nix>
    ./lib/modules/wireguard_exporter.nix
    ./lib/modules/wgipamd.nix
  ];

  # Overlays for unstable and out-of-tree packages.
  nixpkgs.overlays = [
    (self: super: {
      prometheus-apcupsd-exporter = unstable.prometheus-apcupsd-exporter;
      wireguard_exporter =
        super.callPackage ./lib/pkgs/wireguard_exporter.nix { };
    })
  ];

  # Use the GRUB 2 boot loader with MBR.
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
        "net.ipv6.conf.${name}.use_tempaddr" = 1;
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
    cmatrix
    flashrom

    # Unstable and out-of-tree packages.
    wireguard_exporter
  ];

  # Use server as a remote builder.
  nix = {
    distributedBuilds = true;
    buildMachines = [{
      hostName = "servnerr-3";
      system = "x86_64-linux";
      maxJobs = 8;
      cores = 2;
      speedFactor = 2;
      supportedFeatures = [ "nixos-test" "benchmark" "big-parallel" "kvm" ];
    }];
  };

  services = {
    # Allow mDNS to reflect between VLANs where necessary for devices such as
    # Google Home and Chromecast.
    avahi = {
      enable = true;
      interfaces = with vars.interfaces; [ "${lan0.name}" "${iot0.name}" ];
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

    prometheus.exporters.apcupsd.enable = true;

    tftpd = {
      enable = true;
      path = "/var/lib/tftp";
    };
  };
}
