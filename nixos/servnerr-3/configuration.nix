# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{ config, pkgs, ... }:

{
  imports = [
    # Hardware configuration.
    ./hardware-configuration.nix

    # Base system configuration.
    ./lib/nix.nix
    ./lib/system.nix
    ./lib/users.nix
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
      enp5s0.useDHCP = true;
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

  # Packages specific to this machine. The base package set is defined in
  # lib/system.nix.
  environment.systemPackages = with pkgs; [ zfs ];

  services = {
    fwupd.enable = true;

    grafana = {
      enable = true;
      # Bind to all interfaces.
      addr = "";
    };

    # Enable the OpenSSH daemon.
    openssh = {
      enable = true;
      passwordAuthentication = false;
    };

    plex.enable = true;
  };

  # TODO: move into own prometheus.nix file.
  services.prometheus = {
    enable = true;
    exporters = {
      node.enable = true;

      # SNMP exporter with data file from release 0.17.0.
      snmp = {
        enable = true;
        configurationPath = builtins.fetchurl {
          url =
            "https://raw.githubusercontent.com/prometheus/snmp_exporter/f0ad4551a5c2023e383bc8dde2222f47dc760b83/snmp.yml";
          sha256 =
            "5c1febe100ce9140c8c59cf3c2a6346a1219dd0966d5cd2926498e88dcd69997";
        };
      };
    };

    alertmanagers =
      [{ static_configs = [{ targets = [ "monitnerr-1:9093" ]; }]; }];

    scrapeConfigs = [
      {
        job_name = "node";
        static_configs = [{
          targets = [
            "monitnerr-1:9100"
            "nerr-3:9100"
            "routnerr-2:9100"
            "servnerr-3:9100"
          ];
        }];
      }
      {
        job_name = "snmp";
        metrics_path = "/snmp";
        params = { module = [ "if_mib" ]; };
        relabel_configs = [
          {
            source_labels = [ "__address__" ];
            target_label = "__param_target";
          }
          {
            source_labels = [ "__param_target__" ];
            target_label = "instance";
          }
          {
            target_label = "__address__";
            replacement = "servnerr-3:9116";
          }
        ];
        static_configs = [{
          targets =
            [ "switch-livingroom01" "switch-office01" "ap-livingroom02" ];
        }];
      }
    ];

    webExternalUrl = "https://prometheus.servnerr.com";
  };

  # root SSH key for remote builds.
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOnN7NbaDhuuBQYPtlLtoUyyS6Q3cjJ/VPrw2IQ31R6F NixOS distributed build"
  ];
}
