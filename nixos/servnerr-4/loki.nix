# Loki log database: single binary mode with filesystem storage, receiving
# the systemd journal from every machine; see nixos/modules/alloy.nix for the
# shipping side. Queries run through Grafana, or logcli against the
# svc:loki Tailscale Service; see nixos/servnerr-4/prometheus.nix.
{ config, pkgs, ... }:

let
  inherit (config.services.loki) dataDir;
  inherit (config.homelab.inventory) tailnetDomain;

  # Log-derived rules, evaluated continuously by the ruler: alerts cover what
  # the metrics stack cannot see (SystemdUnitFailed already catches failed
  # units, including nightly upgrades), and the recording rule feeds per-host
  # log freshness into Prometheus for the HostLogsStalled alert; see
  # prometheus-alerts.nix. LogQL regexes use raw backtick strings.
  #
  # Every pattern-matching rule is scoped to the units which can legitimately
  # produce its message (the kernel logs with no unit, PID 1 as init.scope).
  # An unscoped pattern feeds back: the ruler logs each evaluation including
  # the rule's own query text, which ships back into Loki and matches the
  # next evaluation, firing the alert forever.
  rules = {
    groups = [
      {
        name = "logs";
        rules = [
          {
            alert = "LogAuthFailures";
            # sshd, sudo in a (collapsed) session scope, and unitless audit
            # messages.
            expr = ''sum by (host) (count_over_time({job="systemd-journal", unit=~"sshd.service|session.scope|user@.+.service|"} |~ `(?i)(failed password|invalid user|authentication failure|password check failed)` [15m])) > 5'';
            annotations.summary = "{{ $labels.host }} logged more than 5 authentication failures in 15 minutes.";
          }
          {
            alert = "OOMKill";
            expr = ''sum by (host) (count_over_time({job="systemd-journal", unit=""} |~ `Out of memory: Killed process|invoked oom-killer` [15m])) > 0'';
            annotations.summary = "{{ $labels.host }} killed a process due to memory pressure.";
          }
          {
            # Restart= loops do not fail the unit, so SystemdUnitFailed never
            # sees them; the scheduled-restart message names the unit in the
            # log line.
            alert = "UnitCrashLooping";
            expr = ''sum by (host) (count_over_time({job="systemd-journal", unit="init.scope"} |= `Scheduled restart job` [10m])) > 5'';
            annotations.summary = "A unit on {{ $labels.host }} is restarting repeatedly; check its journal.";
          }
          {
            alert = "KernelIOError";
            expr = ''sum by (host) (count_over_time({job="systemd-journal", unit=""} |~ `(?i)i/o error` [15m])) > 0'';
            annotations.summary = "{{ $labels.host }} kernel reports I/O errors.";
          }
          {
            record = "host:log_lines:count1h";
            expr = ''sum by (host) (count_over_time({job="systemd-journal"}[1h]))'';
          }
        ];
      }
    ];
  };

  # Local ruler storage is per-tenant; with auth disabled everything lives
  # under the static "fake" tenant.
  rulesDir = pkgs.writeTextDir "fake/logs.yaml" (builtins.toJSON rules);
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

      # The ruler evaluates the log-derived rules above: alerts go to the
      # local Alertmanager (v2: its v1 API no longer exists), and recording
      # rules are remote-written into the local Prometheus, which enables its
      # receiver for this; see prometheus.nix.
      ruler = {
        storage = {
          type = "local";
          local.directory = rulesDir;
        };
        rule_path = "${dataDir}/ruler";
        alertmanager_url = "http://127.0.0.1:${toString config.services.prometheus.alertmanager.port}";
        enable_alertmanager_v2 = true;
        # Source links in alert notifications land somewhere useful.
        external_url = "https://grafana.${tailnetDomain}/";
        wal.dir = "${dataDir}/ruler-wal";
        remote_write = {
          enabled = true;
          clients.prometheus.url = "http://127.0.0.1:${toString config.services.prometheus.port}/api/v1/write";
        };
      };

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
