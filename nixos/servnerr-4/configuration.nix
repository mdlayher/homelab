{ config, pkgs, ... }:

let
  # Grafana dashboards from the repository, rewritten to reference the
  # provisioned Prometheus datasource by name.
  dashboards =
    pkgs.runCommand "grafana-dashboards"
      {
        nativeBuildInputs = [ pkgs.jq ];
      }
      ''
        mkdir -p $out
        for f in ${../../grafana}/*.json; do
          jq 'del(.id, .__inputs, .__requires)' "$f" \
            | sed -e 's/''${DS_SERVNERR-3_PROMETHEUS}/Prometheus/g' -e 's/servnerr-3 Prometheus/Prometheus/g' \
            > "$out/$(basename "$f")"
        done
      '';
in
{
  imports = [
    # Hardware and base system configuration. The shared base system lives in
    # nixos/modules/ and is imported by flake.nix.
    ./hardware-configuration.nix
    ./networking.nix
    ./storage.nix

    # Service configuration.
    ./containers.nix
    ./dev.nix
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

      # Declarative datasource and dashboards; anything else in the Grafana
      # database is disposable.
      provision = {
        enable = true;
        datasources.settings.datasources = [
          {
            name = "Prometheus";
            type = "prometheus";
            uid = "prometheus";
            url = "http://localhost:${toString config.services.prometheus.port}";
            isDefault = true;
          }
        ];
        dashboards.settings.providers = [
          {
            name = "homelab";
            options.path = dashboards;
          }
        ];
      };

      settings = {
        server = {
          # Bind to all interfaces.
          http_addr = "";

          # Advertise the Tailscale Services TLS frontend, so links Grafana
          # generates resolve anywhere on the tailnet.
          root_url = "https://grafana.${config.homelab.inventory.tailnetDomain}/";
        };

        # NixOS 26.05 no longer ships a default secret_key. Grafana was reset
        # (fresh /var/lib/grafana) when switching to the flake, so this key is
        # a new random value stored in sops.
        security.secret_key = "$__file{${config.sops.secrets."grafana/secret_key".path}}";
      };
    };

    # Enable the OpenSSH daemon.
    openssh.enable = true;
  };
}
