# Grafana Alloy ships this machine's systemd journal to Loki on the server;
# see nixos/servnerr-4/loki.nix for the server side.
{
  config,
  inputs,
  lib,
  ...
}:

let
  inherit (config.homelab.inventory) domain roles;

  # Loki's port on a server role holder, from that machine's own
  # configuration.
  lokiPort =
    server:
    inputs.self.nixosConfigurations.${server}.config.services.loki.configuration.server.http_listen_port;

  # Push to every server role holder, so both generations receive logs during
  # a hardware swap; see nixos/inventory/default.nix.
  endpoints = lib.concatMapStrings (server: ''
    endpoint {
        url = "http://${server}.${domain}:${toString (lokiPort server)}/loki/api/v1/push"
      }
  '') roles.server;

  # Journals of this machine's nixos-containers, read from the host
  # filesystem: containers on restricted VLANs (dev0) cannot push over the
  # network themselves. Entries carry the container's hostname, so the shared
  # relabeling labels them like any other host.
  containerSources = lib.concatMapStrings (name: ''

    loki.source.journal "container_${lib.replaceStrings [ "-" ] [ "_" ] name}" {
      path          = "/var/lib/nixos-containers/${name}/var/log/journal"
      forward_to    = [loki.write.server.receiver]
      relabel_rules = loki.relabel.journal.rules
      labels        = {job = "systemd-journal"}
    }
  '') (lib.attrNames config.containers);

  # Journals of this machine's microvms, likewise read from the host
  # filesystem: each guest writes its journal through a virtiofs share; see
  # nixos/servnerr-4/dev.nix.
  microvmSources = lib.concatMapStrings (name: ''

    loki.source.journal "microvm_${lib.replaceStrings [ "-" ] [ "_" ] name}" {
      path          = "/var/lib/microvms/${name}/journal"
      forward_to    = [loki.write.server.receiver]
      relabel_rules = loki.relabel.journal.rules
      labels        = {job = "systemd-journal"}
    }
  '') (lib.attrNames (config.microvm.vms or { }));
in
{
  services.alloy = {
    enable = true;
    extraFlags = [
      # The HTTP server carries both the debug UI and the metrics endpoint;
      # expose it so Prometheus on the server can scrape it. The port is
      # discovered from this flag; see nixos/servnerr-4/prometheus.nix.
      "--server.http.listen-addr=0.0.0.0:12345"
      "--disable-reporting"
    ];
  };

  environment.etc."alloy/config.alloy".text = ''
    // Journal entries are labeled with the machine and originating unit; keep
    // the label set small, high-cardinality detail stays in the log lines.
    loki.relabel "journal" {
      forward_to = []

      rule {
        source_labels = ["__journal__hostname"]
        target_label  = "host"
      }

      rule {
        source_labels = ["__journal__systemd_unit"]
        target_label  = "unit"
      }

      // Collapse units with one uniquely named instance per connection or
      // login, so each does not mint a new stream: sshd and the ssh-agent
      // relay (the ssh_banner probe alone would create one per minute per
      // machine), and logind's numbered session scopes. Stable instances
      // (container@, serial-getty@) keep their names.
      rule {
        source_labels = ["unit"]
        regex         = "sshd@.+"
        replacement   = "sshd.service"
        target_label  = "unit"
      }

      rule {
        source_labels = ["unit"]
        regex         = "ssh-agent-relay@.+"
        replacement   = "ssh-agent-relay.service"
        target_label  = "unit"
      }

      rule {
        source_labels = ["unit"]
        regex         = "session-.+\\.scope"
        replacement   = "session.scope"
        target_label  = "unit"
      }
    }

    loki.source.journal "journal" {
      forward_to    = [loki.write.server.receiver]
      relabel_rules = loki.relabel.journal.rules
      labels        = {job = "systemd-journal"}
    }
    ${containerSources}${microvmSources}
    // Push to Loki on the server over the LAN.
    loki.write "server" {
      ${endpoints}
    }
  '';
}
