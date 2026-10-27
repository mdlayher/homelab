{
  config,
  lib,
  pkgs,
  ...
}:

{
  # The module's controller options lack the system log source, which
  # UnPoller reads as save_syslog.
  imports = [
    {
      options.services.prometheus.exporters.unpoller.controllers = lib.mkOption {
        type = lib.types.listOf (
          lib.types.submodule {
            options.save_syslog = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "Collect the controller's system log for Loki.";
            };
          }
        );
      };
    }
  ];

  # The UniFi Network application, the controller for the UniFi switches and
  # access points. The controller moves to another host by restoring one
  # of its backups there. Configuration beyond adoption is terraform/unifi.
  #
  # A fresh controller wants its setup wizard finished before it answers
  # tofu. unifi-bootstrap beside this file does that over the wizard's
  # endpoints, which accept unauthenticated calls until setup completes:
  # it creates the admin from secrets/unifi.yaml and the read-only account
  # UnPoller uses (below). From the repository root in the development
  # container, once the controller is up:
  #
  #   sops-gate exec-env secrets/unifi.yaml -- nixos/servnerr-4/unifi-bootstrap <name>
  #
  # where <name> is the controller's display name. Then adopt the built-in
  # Default network into the state (unifi-bootstrap prints its id) and
  # apply:
  #
  #   sops-gate tofu-import unifi unifi_network.mgmt0 <id>
  #   sops-gate tofu-apply unifi
  #
  # Devices on the management LAN show up for adoption through discovery
  # (see the mgmt0 openings in networking.nix); adoption is done in the UI.
  services.unifi = {
    enable = true;

    # The controller, its JDK and its MongoDB come from the unstable
    # channel. MongoDB is its own binary build: the module's default builds
    # MongoDB from source, and no binary cache carries it.
    unifiPackage = pkgs.unstable.unifi;
    jrePackage = config.services.unifi.unifiPackage.passthru.jrePackage;
    mongodbPackage = pkgs.unstable.mongodb-ce;
  };

  # The web UI and API for tailnet clients, the development container's
  # tofu among them, as svc:unifi. The controller terminates TLS itself, so
  # the service forwards TCP.
  homelab.tailscale.services.unifi."tcp:8443" = "tcp://127.0.0.1:8443";

  # Device, port, radio and client metrics for the switches and access
  # points, from the controller. Prometheus finds the exporter on its own
  # (see prometheus.nix). Every series vanishes while the controller is
  # down.
  services.prometheus.exporters.unpoller = {
    enable = true;
    controllers = [
      {
        url = "https://localhost:8443";
        user = "unpoller";
        pass = config.sops.secrets."unifi/unpoller_password".path;
        # The controller serves a self-signed certificate.
        verify_ssl = false;

        # The controller's system log and anomalies, pushed to Loki
        # (loki.svc) as {job="unpoller"} streams, one per kind in the
        # application label (unifi_system_log, unifi_anomaly). UnPoller
        # stops a round at the first source that fails, and the
        # controller answers the events, alarms and IDS sources with
        # errors, so those stay off.
        save_syslog = true;
        save_anomalies = true;
      }
    ];
    loki.url = "http://loki.svc.${config.homelab.inventory.zone}:${toString config.services.loki.configuration.server.http_listen_port}";
  };

  # The read-only account's password, which unifi-admins also reads to
  # create the account.
  sops.secrets."unifi/unpoller_password" = {
    owner = config.services.prometheus.exporters.unpoller.user;
    restartUnits = [ "prometheus-unpoller-exporter.service" ];
  };
}
