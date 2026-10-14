# Periodic snapshots of the Zigbee mesh as Home Assistant's ZHA integration
# sees it: each device's parent router, the LQI of every neighbor link and
# the routes each router holds. ZHA keeps only a cache of these, which its
# own scans overwrite every few hours; this keeps their history.
#
# The full tables go to Loki in the shape of the router's network snapshot
# (nixos/routnerr-3/network-snapshot.nix), one line per device, link and
# route. Devices and links, which are bounded by the mesh itself, also go to
# Prometheus through node_exporter's textfile collector; routes stay in Loki
# only.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  # Reached by name the way prometheus.nix's homeassistant job reaches it.
  inherit (config.homelab.inventory) domain;
  hass = lib.head (config.homelab.inventory.tagged [ "homeassistant" ]);
  url = "http://${hass.dnsName}.${domain}:8123";

  # Prometheus's long-lived Home Assistant token, which authenticates the
  # websocket API as well as the REST one. systemd reads it on the unit's
  # behalf, so the secret keeps its owner.
  token = config.sops.secrets."prometheus/homeassistant_token".path;
  inherit (config.homelab) textfileDir textfileGroup;

  snapshot = pkgs.writers.writePython3Bin "zigbee-snapshot" { } (
    builtins.readFile ./zigbee-snapshot.py
  );
in
{
  sops.secrets."prometheus/homeassistant_token".restartUnits = [ "zigbee-snapshot.service" ];

  systemd = {
    timers.zigbee-snapshot = {
      description = "Sample the Zigbee mesh for Loki and Prometheus";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "2m";
        OnUnitActiveSec = "15m";
      };
    };

    # Written to stdout for the reasons given in the router's network
    # snapshot; the lines arrive labeled unit="zigbee-snapshot.service", and
    # nixos/modules/alloy.nix gives them job="zigbee-snapshot".
    services.zigbee-snapshot = {
      description = "Zigbee mesh snapshot";
      serviceConfig = {
        Type = "oneshot";
        SyslogIdentifier = "zigbeesnap";
        DynamicUser = true;
        SupplementaryGroups = [ textfileGroup ];
        ReadWritePaths = [ textfileDir ];
        LoadCredential = [ "token:${token}" ];
        ExecStart = "${lib.getExe snapshot} ${url} %d/token ${textfileDir}/zigbee.prom";
      };
    };
  };
}
