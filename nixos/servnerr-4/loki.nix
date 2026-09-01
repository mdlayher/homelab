# Loki log database: single binary mode with filesystem storage, receiving
# the systemd journal from every machine; see nixos/modules/alloy.nix for the
# shipping side. Queries run through Grafana, or logcli against the
# svc:loki Tailscale Service; see nixos/servnerr-4/prometheus.nix.
{ config, ... }:

let
  inherit (config.services.loki) dataDir;
in
{
  services.loki = {
    enable = true;

    configuration = {
      # The tailnet policy and LAN trust boundaries gate access instead of
      # multi-tenancy.
      auth_enabled = false;

      server = {
        # The push and query API, reachable over the LAN by the machines and
        # published as svc:loki for tailnet clients.
        http_listen_port = 3100;
        # gRPC is only used internally in single binary mode.
        grpc_listen_address = "127.0.0.1";
      };

      # Single node: one replica in an in-memory ring, all state on local
      # disk under dataDir.
      common = {
        path_prefix = dataDir;
        replication_factor = 1;
        # Advertised address for every internal component, notably the query
        # frontend: it must be loopback to match the gRPC listener above, or
        # the querier computes results and then fails to deliver them,
        # hanging every query. Setting this only on the ring is not enough,
        # since the frontend is not a ring member and would fall back to
        # autodetecting the LAN interface.
        instance_addr = "127.0.0.1";
        ring.kvstore.store = "inmemory";
        storage.filesystem = {
          chunks_directory = "${dataDir}/chunks";
          rules_directory = "${dataDir}/rules";
        };
      };

      schema_config.configs = [
        {
          from = "2026-09-01";
          store = "tsdb";
          object_store = "filesystem";
          schema = "v13";
          index = {
            prefix = "index_";
            period = "24h";
          };
        }
      ];

      # The compactor deletes chunks past retention; without it the store
      # grows forever.
      compactor = {
        retention_enabled = true;
        delete_request_store = "filesystem";
      };
      limits_config.retention_period = "90d";

      analytics.reporting_enabled = false;
    };
  };
}
