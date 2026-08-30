{ config, pkgs, ... }:

{
  imports = [
    # Hardware and base system configuration. The shared base system lives in
    # nixos/modules/ and is imported by flake.nix.
    ./hardware-configuration.nix
    ./networking.nix
    ./storage.nix

    # Service configuration.
    ./containers.nix
    ./prometheus.nix
  ];

  system.stateVersion = "22.11";

  # Secrets for this machine, encrypted with sops. Edit with:
  #   sops nixos/servnerr-4/secrets.yaml
  sops = {
    defaultSopsFile = ./secrets.yaml;
    secrets."grafana/secret_key".owner = "grafana";
  };

  boot = {
    # Use the systemd-boot EFI boot loader.
    loader = {
      systemd-boot.enable = true;
      efi.canTouchEfiVariables = true;
    };

    # systemd-based initrd.
    initrd.systemd.enable = true;

    # Enable extra filesystems.
    supportedFilesystems = {
      ntfs = true;
      zfs = true;
    };

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
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Restart = "always";
    };
  };

  # The Ryzen 3900X runs amd-pstate in EPP mode, which only offers the
  # performance and powersave governors; powersave with the default EPP scales
  # down when load is low.
  powerManagement.cpuFreqGovernor = "powersave";

  # Packages specific to this machine. The base package set is defined in
  # nixos/modules/common.nix.
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

    grafana = {
      enable = true;
      settings = {
        # Bind to all interfaces.
        server.http_addr = "";

        # NixOS 26.05 no longer ships a default secret_key. Grafana was reset
        # (fresh /var/lib/grafana) when switching to the flake, so this key is
        # a new random value stored in sops.
        security.secret_key = "$__file{${config.sops.secrets."grafana/secret_key".path}}";
      };
    };

    # Enable the OpenSSH daemon.
    openssh = {
      enable = true;
      settings.PasswordAuthentication = false;
    };
  };

  # root SSH key for remote builds.
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIP3+HUx05h15g95ID/lWbU5uvF6TLr2XESmthQjU7qvR NixOS distributed build"
  ];
}
