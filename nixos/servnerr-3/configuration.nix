# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{ pkgs, ... }:

let vars = import ./lib/vars.nix;

in {
  imports = [
    # Hardware configuration.
    ./hardware-configuration.nix

    # Base system configuration.
    ./lib/nix.nix
    ./lib/system.nix
    ./lib/users.nix
    ./lib/node_exporter.nix

    # Service configuration.
    ./prometheus.nix

    # Out-of-tree modules.
    ./lib/modules/keylight_exporter.nix
  ];

  # Overlays for out-of-tree packages.
  nixpkgs.overlays = [
    (self: super: {
      keylight_exporter =
        super.callPackage ./lib/pkgs/keylight_exporter.nix { };
    })
  ];

  networking = {
    # Host name and ID.
    hostName = "servnerr-3";
    hostId = "efdd2a1b";

    # No local firewall.
    firewall.enable = false;

    # Set up a bridge interface for VMs which is tagged into a lab VLAN.
    bridges.br0.interfaces = [ "enp6s0" ];

    # Use DHCP for all interfaces, but force the deprecated global setting off.
    useDHCP = false;
    interfaces = {
      # 1GbE on management.
      enp5s0.useDHCP = true;

      # 10GbE VLAN.
      enp11s0.useDHCP = true;

      # 1GbE on Lab VLAN.
      br0.useDHCP = false;
    };
  };

  boot = {
    # Use the systemd-boot EFI boot loader.
    loader = {
      systemd-boot.enable = true;
      efi.canTouchEfiVariables = true;
    };

    # Enable ZFS.
    supportedFilesystems = [ "zfs" ];

    # Latest Linux kernel for better hwmon support.
    kernelPackages = pkgs.linuxPackages_latest;
    kernelModules = [ "drivetemp" ];

    kernelParams = [
      # Enable serial console.
      "console=ttyS0,115200n8"
      # 24GiB ZFS ARC.
      "zfs.zfs_arc_max=25769803776"
    ];
  };

  # Start getty over serial console.
  systemd.services."serial-getty@ttyS0" = {
    enable = true;
    # Make sure agetty spawns at boot and always restarts whenever it
    # exits due to user logout.
    wantedBy = [ "multi-user.target" ];
    serviceConfig = { Restart = "always"; };
  };

  # Allow the use of Plex.
  nixpkgs.config.allowUnfree = true;

  # Scale down CPU frequency when load is low.
  powerManagement.cpuFreqGovernor = "ondemand";

  # Packages specific to this machine. The base package set is defined in
  # lib/system.nix.
  environment.systemPackages = with pkgs; [ zfs ];

  services = {
    apcupsd.enable = true;

    grafana = {
      enable = true;
      # Bind to all interfaces.
      addr = "";
    };

    # Export ZFS pool via NFS to trusted LAN.
    nfs.server = {
      enable = true;
      exports = with vars.interfaces.lan0; ''
        /primary 192.168.1.0/24(rw,sync,no_subtree_check,crossmnt) fd9e:1a04:f01d::/64(rw,sync,no_subtree_check,crossmnt)
      '';
    };

    # Enable the OpenSSH daemon.
    openssh = {
      enable = true;
      passwordAuthentication = false;
    };

    plex.enable = true;

    zfs.autoScrub.enable = true;
  };

  virtualisation = {
    docker.enable = true;
    libvirtd.enable = true;
  };

  # root SSH key for remote builds.
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIP3+HUx05h15g95ID/lWbU5uvF6TLr2XESmthQjU7qvR NixOS distributed build"
  ];

  docker-containers = {
    # promlens running on TCP/9091 adjacent to Prometheus.
    promlens = {
      image = "promlabs/promlens";
      ports = [ "9091:8080" ];
      volumes = [ "/var/lib/promlens:/var/lib/promlens" ];
    };
  };
}
