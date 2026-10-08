# Loki log database: single binary mode with filesystem storage, receiving
# the systemd journal from every machine; see nixos/modules/alloy.nix for the
# shipping side. Queries run through Grafana, or logcli against the
# svc:loki Tailscale Service; see nixos/servnerr-4/prometheus.nix.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (config.services.loki) dataDir;
  inherit (config.homelab.inventory) hosts tailnetDomain;

  # Journal streams which can carry authentication failures: sshd, sudo in a
  # (collapsed) session scope, and unitless audit messages.
  authUnits = ''job="systemd-journal", unit=~"sshd.service|session.scope|user@.+.service|"'';

  # One line per failed attempt, anchored so the log's second mention of the
  # same attempt does not count it twice. Unknown accounts: sshd logs
  # "Invalid user X from ..." and later "Connection closed by invalid user X
  # ..." for the same connection. Known accounts: sshd's "Connection closed
  # by authenticating user X ..." is its only record of a connection that
  # named a real account and never authenticated (a bot trying root, or a
  # declined FIDO2 touch), and a rejected sudo or login password logs both
  # unix_chkpwd's "password check failed for user (X)" and pam_unix's
  # "authentication failure; ...". Password authentication is disabled
  # everywhere, so sshd's "Failed password" never appears. The server's
  # ssh_banner probe hangs up before naming a user and logs only
  # "Connection closed by <addr> port N [preauth]", which nothing here
  # matches.
  invalidUserLine = "^Invalid user ";
  authFailureLine = "^(Connection closed by authenticating user |password check failed for user )";

  # The lines matching a pattern, from streams matching any extra selector;
  # the per-host count an alert compares, and the Grafana Explore link its
  # logs_url annotation carries to the source addresses (which stay in the
  # lines rather than becoming alert labels).
  failures = line: extra: "{${extra}${authUnits}} |~ `${line}`";
  countFailures = line: "sum by (host) (count_over_time(${failures line ""} [15m]))";
  failureLogs = line: exploreURL (failures line ''host="__host__", '');

  exploreURL = import ./explore-url.nix { inherit lib tailnetDomain; };

  # The LG TVs' Glasshouse servers forward their logs here (lgtv/hosts.nix).
  lgtv = import ../../lgtv/hosts.nix;

  # consrv, the serial consoles on the KVM (see pikvm/), logs a line per key
  # a client offers, "<addr>: accepted|rejected public key authentication
  # for ...", and one per session, naming the console in quotes: "<addr>:
  # opened serial connection "router": ...". Clients of svc:consrv arrive
  # through the KVM's tailscale serve, so their address is 127.0.0.1.
  consrvLines = filter: ''{job="systemd-journal", unit="consrv.service"} |= `${filter}`'';
  consrvAuth = verdict: consrvLines ": ${verdict} public key authentication";
  consrvSessions = consrvLines ": opened serial connection ";

  # Log-derived rules, evaluated continuously by the ruler: alerts cover what
  # the metrics stack cannot see (SystemdUnitFailed already catches failed
  # units, including nightly upgrades), and the recording rule feeds per-host
  # log freshness into Prometheus for the LokiHostLogsStalled alert; see
  # alerts/systems.nix. LogQL regexes use raw backtick strings.
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
        # Alerts sorted alphabetically, with the recording rule last.
        rules = [
          {
            alert = "KernelIOError";
            expr = ''sum by (host) (count_over_time({job="systemd-journal", unit=""} |~ `(?i)i/o error` [15m])) > 0'';
            annotations.summary = "{{ $labels.host }} kernel reports I/O errors.";
          }
          {
            alert = "KernelOOMKill";
            expr = ''sum by (host) (count_over_time({job="systemd-journal", unit=""} |~ `Out of memory: Killed process|invoked oom-killer` [15m])) > 0'';
            annotations.summary = "{{ $labels.host }} killed a process due to memory pressure.";
          }
          {
            alert = "PAMAuthFailures";
            # Failures against accounts that exist. A mistyped sudo
            # password or a declined touch is one or two in a row and stays
            # under the threshold; SSHInvalidUsers below covers the scanners
            # guessing account names, which are noisier at a lower count.
            expr = "${countFailures authFailureLine} > 3";
            annotations = {
              summary = "{{ $labels.host }} logged more than 3 authentication failures for existing accounts in 15 minutes.";
              logs_url = failureLogs authFailureLine;
            };
          }
          {
            alert = "SSHInvalidUsers";
            # No legitimate client names an account that does not exist, so
            # a couple of these means a scanner has found the SSH port: the
            # first sign of a firewall hole. One tolerates a typo.
            expr = "${countFailures invalidUserLine} > 1";
            annotations = {
              summary = "{{ $labels.host }} logged {{ $value }} SSH attempts for nonexistent accounts in 15 minutes.";
              logs_url = failureLogs invalidUserLine;
            };
          }
          {
            # A client offers each key it holds in turn, so a legitimate login
            # can log rejections seconds before the key consrv accepts.
            # Rejections with no acceptance in the same window are someone
            # without a key; the window is short so that a login of the
            # admin's does not hide them for long. Per host, since the
            # address does not identify svc:consrv clients.
            alert = "SerialConsoleAuthRejected";
            expr = "sum by (host) (count_over_time(${consrvAuth "rejected"} [2m])) unless on (host) sum by (host) (count_over_time(${consrvAuth "accepted"} [2m]))";
            annotations = {
              summary = "consrv on {{ $labels.host }} rejected serial console logins with no successful one.";
              logs_url = exploreURL ''{host="__host__", job="systemd-journal", unit="consrv.service"} |= `public key authentication`'';
            };
          }
          {
            # A serial console session is break-glass access, so each one is
            # announced in the ops channel rather than raised as an alert;
            # see the notify route in prometheus.nix.
            alert = "SerialConsoleLogin";
            expr = ''sum by (host, console) (count_over_time(${consrvSessions} | regexp `opened serial connection "(?P<console>[^"]+)"` [5m]))'';
            labels.notify = "ops";
            annotations = {
              summary = "Opened a session on the {{ $labels.console }} serial console";
              logs_url = exploreURL ''{host="__host__", job="systemd-journal", unit="consrv.service"}'';
            };
          }
          {
            # Restart= loops do not fail the unit, so SystemdUnitFailed never
            # sees them; the scheduled-restart message names the unit in the
            # log line. It is extracted as "service" because "unit" is the
            # stream's own label, always init.scope for these lines.
            alert = "SystemdUnitCrashLooping";
            expr = ''sum by (host, service) (count_over_time({job="systemd-journal", unit="init.scope"} |= `Scheduled restart job` | regexp `^(?P<service>[^:]+): Scheduled restart job` [10m])) > 5'';
            annotations = {
              summary = "{{ $labels.service }} on {{ $labels.host }} is restarting repeatedly; check its journal.";
              logs_url = exploreURL ''{host="__host__", job="systemd-journal", unit="init.scope"} |= `Scheduled restart job`'';
            };
          }
          {
            record = "host:log_lines:count1h";
            expr = ''sum by (host) (count_over_time({job="systemd-journal"}[1h]))'';
          }
          # smartd's own notifications are off and the smartctl exporter has
          # no self-test metric, so a test that fails without moving an
          # attribute counter is visible only in this log line. It is
          # recorded rather than alerted on here so that the alert can join
          # the drive's serial from the exporter; see SMARTSelfTestFailed in
          # alerts/storage.nix. The device keeps its kernel name, without
          # the /dev/ prefix, which is what that join matches on.
          {
            record = "host_device:smartd_selftest_errors:count15m";
            expr = ''sum by (host, device) (count_over_time({job="systemd-journal", unit="smartd.service"} |~ `Self-Test Log error count increased|new Self-Test Log error` | regexp `^Device: /dev/(?P<device>[^ ,]+)` [15m]))'';
          }
          # IS-IS adjacencies dropped by BFD, per circuit end, for
          # ISISAdjacencyFlapping in alerts/routing.nix. The window
          # matches the ruler's default one-minute interval, so each drop
          # lands in one sample. Interconnect circuits only, so the IS-IS
          # lab (isisLab in dev.nix) records nothing.
          {
            record = "host_circuit:isis_bfd_drops:count1m";
            expr = ''sum by (host, circuit) (count_over_time({job="systemd-journal", unit="frr.service"} |= `bfd session went down` | regexp `Adjacency to \S+ \((?P<circuit>[^)]+)\)` | circuit =~ "icl-.+" [1m]))'';
          }
          # The binary cache failing a client's nightly upgrade, for
          # NixCacheFailing in alerts/systems.nix: unreachable, or serving
          # a path whose signature the client does not trust. Either way the
          # client builds that path itself instead.
          {
            record = "host:nix_cache_failures:count1m";
            expr = ''sum by (host) (count_over_time({job="systemd-journal", unit="nixos-upgrade.service"} |= `nix-cache.svc.${config.homelab.inventory.zone}` |~ `unable to download|not signed by any of the keys` [1m]))'';
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
  # The raw syslog format below is gated behind alloy's experimental
  # stability level.
  services.alloy.extraFlags = [ "--stability.level=experimental" ];

  # Syslog from devices that cannot run alloy. Rendered through sops at
  # activation because the relabeling below matches inventory addresses.
  sops.templates."alloy-syslog.alloy" = {
    content = ''
      loki.source.syslog "lan" {
        listener {
          address       = "0.0.0.0:5514"
          protocol      = "udp"
          // The CyberPower cards each speak their own almost-RFC3164
          // dialect and no two firmwares agree, so ship each datagram
          // verbatim rather than parsing it.
          syslog_format = "raw"
          labels        = {job = "syslog", site = "${config.homelab.site}"}
        }
        relabel_rules = loki.relabel.syslog.rules
        forward_to    = [loki.write.server.receiver]
      }

      // The LG TVs' logs, forwarded by Glasshouse as RFC 5424 (see lgtv/).
      // Each names itself in the hostname field. Over IPv4 and IPv6, as the
      // TVs resolve this machine to either.
      loki.source.syslog "lgtv" {
        listener {
          address       = "[::]:${toString lgtv.syslogPort}"
          protocol      = "udp"
          syslog_format = "rfc5424"
          labels        = {job = "syslog", site = "${config.homelab.site}"}
          // Glasshouse stamps each line with when the TV wrote it, so the
          // backlog it sends at startup keeps its own times.
          use_incoming_timestamp = true
        }
        relabel_rules = loki.relabel.lgtv.rules
        forward_to    = [loki.write.server.receiver]
      }

      // The host label from the hostname field, as journal streams carry
      // the machine's. The message ID names the TV log a line came from
      // (system, glasshouse or kernel), and the app name the TV process
      // that wrote it, which the message itself does not repeat.
      loki.relabel "lgtv" {
        forward_to = []

        rule {
          source_labels = ["__syslog_message_hostname"]
          target_label  = "host"
        }

        rule {
          source_labels = ["__syslog_message_msg_id"]
          target_label  = "source"
        }

        rule {
          source_labels = ["__syslog_message_app_name"]
          target_label  = "app"
        }
      }

      // Label messages with a host name by sender address, mirroring the
      // host label on journal streams. Raw mode parses nothing, and the
      // cards' self-reported identities are unusable anyway.
      loki.relabel "syslog" {
        forward_to = []

        rule {
          source_labels = ["__syslog_connection_ip_address"]
          regex         = "${hosts.ups01.ipv4}"
          replacement   = "ups01"
          target_label  = "host"
        }

        rule {
          source_labels = ["__syslog_connection_ip_address"]
          regex         = "${hosts.pdu01.ipv4}"
          replacement   = "pdu01"
          target_label  = "host"
        }
      }
    '';
    mode = "0444";
    restartUnits = [ "alloy.service" ];
  };

  environment.etc."alloy/syslog.alloy".source = config.sops.templates."alloy-syslog.alloy".path;

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
      limits_config = {
        # A year of history; disk is plentiful.
        retention_period = "365d";

        # The router's nginx serves a clearnet page, so its logs hold
        # visitor addresses from outside the homelab (see the router host's
        # dn42-page.nix); thirty days is enough to answer "did they fetch
        # the page" and forgets them well inside the year. The counters
        # alloy derives carry no address and keep Prometheus's retention.
        retention_stream = [
          {
            selector = ''{unit=~"nginx_access|nginx.service"}'';
            priority = 1;
            period = "30d";
          }
        ];
      };

      analytics.reporting_enabled = false;
    };
  };
}
