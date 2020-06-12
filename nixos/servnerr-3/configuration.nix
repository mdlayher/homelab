# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{ pkgs, ... }:

let
  vars = import ./lib/vars.nix;
  unstable = import <unstable> { };

in {
  disabledModules = [
    # Replaced with unstable for additional exporters.
    "services/monitoring/prometheus/exporters.nix"
  ];

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

    # Unstable or out-of-tree modules.
    <unstable/nixos/modules/services/monitoring/prometheus/exporters.nix>
  ];

  # Overlays for unstable and out-of-tree packages.
  nixpkgs.overlays = [
    (self: super: {
      prometheus-apcupsd-exporter = unstable.prometheus-apcupsd-exporter;
      prometheus-keylight-exporter = unstable.prometheus-keylight-exporter;
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
      enp11s0 = {
        mtu = 9000;
        useDHCP = true;
      };

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

  containers = {
    # Plex server running containerized and on unstable for faster updates.
    plex = {
      autoStart = true;
      bindMounts = {
        # Mount the existing data directory.
        "/var/lib/plex" = {
          hostPath = "/var/lib/plex";
          isReadOnly = false;
        };
        # Mount the ZFS pool as read-only.
        "/primary/media" = {
          hostPath = "/primary/media";
          isReadOnly = true;
        };
      };
      config = { config, pkgs, ... }:
        let unstable = import <unstable> { config.allowUnfree = true; };
        in {
          services.plex = {
            enable = true;
            package = unstable.plex;
          };
        };
    };

    # UniFi controller running containerized and on unstable for faster updates.
    unifi = {
      autoStart = true;
      config = { config, pkgs, ... }:
        let unstable = import <unstable> { config.allowUnfree = true; };
        in {
          services.unifi = {
            enable = true;
            unifiPackage = unstable.unifi;
          };
        };
    };
  };
}
