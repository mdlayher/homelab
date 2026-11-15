{ config, pkgs, ... }:

{
  imports = [
    # Hardware and base system configuration. The shared base system lives in
    # nixos/modules/ and is imported by flake.nix.
    ./hardware-configuration.nix
    ./networking.nix
    ./storage.nix

    ./interconnect.nix
    # For the circuit accounting counters the interconnect module keeps;
    # the router and edges run it for the same reason and more.
    ../modules/nftables-exporter.nix

    # Service configuration.
    ./agent-triage.nix
    ./audit.nix
    ../modules/coredns.nix
    ./asus-ec-sensors.nix
    ./dev.nix
    ./hba-metrics.nix
    ./inventory-metrics.nix
    ./nix-cache.nix
    ./loki.nix
    ./prometheus.nix
    ./prusa.nix
    ./rclone-backup.nix
    ./tailnet-audit.nix
    ./unifi.nix
    ./zigbee-snapshot.nix
  ];

  # This machine is at the home site; see nixos/inventory/.
  homelab.site = "azo";

  # The dn42 RTR cache; see modules/rtr-cache.nix.
  homelab.rtrCache.enable = true;

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

    # The motherboard's Nuvoton Super I/O, which carries its fan speeds and
    # voltage rails. The firmware claims the chip's I/O ports, so nct6775
    # reaches it through ASUS's WMI interface on boards it lists, this one
    # included; nothing loads the module on its own because the chip has no
    # device ID to match.
    kernelModules = [ "nct6775" ];
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
        # The NIS server's only consumer is the local apcupsd exporter.
        NISIP 127.0.0.1
      '';
    };

    grafana = {
      enable = true;

      # Declarative datasources and dashboards; anything else in the
      # Grafana database is disposable. Dashboards come only from
      # grafana/dashboards/ and cannot be saved or deleted in the UI.
      provision = {
        enable = true;
        dashboards.settings.providers = [
          {
            name = "homelab";
            allowUiUpdates = false;
            disableDeletion = true;
            options.path = ./grafana/dashboards;
          }
        ];
        datasources.settings.datasources = [
          {
            name = "Prometheus";
            type = "prometheus";
            uid = "prometheus";
            url = "http://localhost:${toString config.services.prometheus.port}";
            isDefault = true;
          }
          {
            name = "Loki";
            type = "loki";
            uid = "loki";
            url = "http://localhost:${toString config.services.loki.configuration.server.http_listen_port}";
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

        # No logins: everyone who reaches Grafana is an anonymous Editor,
        # the role Explore needs, and who reaches it is decided by the
        # tailnet policy and the firewalls. Dashboards and datasources are
        # provisioned, so nothing needs an admin.
        "auth.anonymous" = {
          enabled = true;
          org_role = "Editor";
        };
        auth.disable_login_form = true;
        "auth.basic".enabled = false;

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
