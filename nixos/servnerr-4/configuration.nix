{ lib, pkgs, ... }:

let
  unstable = import <nixos-unstable-small> { };
  vars = import ./lib/vars.nix;

in {
  imports = [
    # Hardware and base system configuration.
    ./hardware-configuration.nix
    ./lib/system.nix
    ./networking.nix
    ./storage.nix

    # Service configuration.
    ./containers.nix
    ./prometheus.nix

    # Unstable or out-of-tree modules.
    # ./lib/modules/zedhook.nix
  ];

  system.stateVersion = "22.11";

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
      "console=ttyS1,115200n8"
      # 56GiB ZFS ARC.
      "zfs.zfs_arc_max=58720256"
    ];
  };

  # Start getty over serial console.
  systemd.services."serial-getty@ttyS1" = {
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
  environment.systemPackages = with pkgs; [
    flac
    mkvtoolnix-cli
    sqlite
    zfs
    zrepl

    # Unstable and out-of-tree packages.
  ];

  services = {
    apcupsd = {
      enable = true;
      configText = ''
        UPSCABLE usb
        UPSTYPE usb
        DEVICE
        UPSCLASS standalone
        UPSMODE disable
      '';
    };

    # Deploy CoreRAD monitor mode on all interfaces.
    corerad = {
      enable = true;

      # Enable as necessary to get development builds of CoreRAD.
      # package = unstable.corerad;

      settings = {
        debug = {
          address = ":9430";
          prometheus = true;
          pprof = true;
        };

        interfaces = [{
          names = [ "mgmt0" ];
          monitor = true;
        }];
      };
    };

    grafana = {
      enable = true;
      # Bind to all interfaces.
      settings.server.http_addr = "";
    };

    # Enable the OpenSSH daemon.
    openssh = {
      enable = true;
      settings.PasswordAuthentication = false;
    };
  };

  virtualisation.libvirtd.enable = true;

  # root SSH key for remote builds.
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIP3+HUx05h15g95ID/lWbU5uvF6TLr2XESmthQjU7qvR NixOS distributed build"
  ];
}
