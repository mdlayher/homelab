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
      forward_to    = [loki.process.journal.receiver]
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
      forward_to    = [loki.process.journal.receiver]
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
      // Deploy provenance lines (nixos/deploy) come from a short-lived
      // logger in an SSH session: journald often cannot read the sender's
      // cgroup before it exits, so their unit is missing as often as not.
      // Key them off the syslog identifier instead, so {unit="deploy"}
      // finds every one.
      rule {
        source_labels = ["__journal_syslog_identifier"]
        regex         = "deploy"
        replacement   = "deploy"
        target_label  = "unit"
      }

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
      forward_to    = [loki.process.journal.receiver]
      relabel_rules = loki.relabel.journal.rules
      labels        = {job = "systemd-journal"}
    }
    ${containerSources}${microvmSources}
    // Everything shipped from a journal passes through here on its way to
    // the writer.
    //
    // The router's nftables drop and reject lines are the one stream worth
    // taking apart: each carries the interface, both MAC addresses, both IP
    // addresses, the protocol and the ports, which is enough to
    // reconstruct a partial neighbor table for hosts that tripped a rule.
    // They are kernel lines, so they arrive with no unit and everything of
    // interest packed into the message text, and reading any of it means a
    // regex over raw lines at query time.
    //
    // The extracted fields become structured metadata, not labels. These
    // lines share the unitless kernel stream that the KernelIOError and
    // KernelOOMKill rules select with unit="" (see
    // nixos/servnerr-4/loki.nix); a label here would move them out of it
    // and leave a trap for the next rule written against that selector.
    // Structured metadata makes the fields queryable without touching
    // stream identity, and Loki has allow_structured_metadata on with the
    // v13 tsdb schema already in use.
    //
    // The match selector keeps the regexes off every other line: this
    // module is shared by every machine, and only the router produces
    // these (a few thousand a day, against far larger journals elsewhere).
    loki.process "journal" {
      forward_to = [loki.write.server.receiver]

      stage.match {
        selector = "{job=\"systemd-journal\"} |~ \"nft .+ (drop|reject): \""

        // One stage per field group rather than a single expression, so a
        // line missing a group still yields the others: a drop on a dn42
        // tunnel has no ethernet header and so no MAC, and ICMP has no
        // ports. A stage whose regex does not match extracts nothing and
        // the pipeline continues.
        stage.regex {
          expression = "nft (?P<nft_rule>.+) (?P<nft_verdict>drop|reject): "
        }

        stage.regex {
          expression = "IN=(?P<nft_in>[^ ]+)"
        }

        stage.regex {
          expression = "OUT=(?P<nft_out>[^ ]+)"
        }

        // MAC= is the ethernet header verbatim: six bytes of destination,
        // six of source, two of ethertype. The source half is the only
        // place these lines name a neighbor's hardware address, which is
        // what makes them a neighbor table at all.
        stage.regex {
          expression = "MAC=(?P<nft_mac_dst>([0-9a-f]{2}:){5}[0-9a-f]{2}):(?P<nft_mac_src>([0-9a-f]{2}:){5}[0-9a-f]{2}):(?P<nft_ethertype>[0-9a-f]{2}:[0-9a-f]{2})"
        }

        stage.regex {
          expression = "SRC=(?P<nft_src>[^ ]+) DST=(?P<nft_dst>[^ ]+)"
        }

        stage.regex {
          expression = "PROTO=(?P<nft_proto>[^ ]+)"
        }

        stage.regex {
          expression = "SPT=(?P<nft_spt>[0-9]+) DPT=(?P<nft_dpt>[0-9]+)"
        }

        stage.structured_metadata {
          values = {
            nft_rule      = "",
            nft_verdict   = "",
            nft_in        = "",
            nft_out       = "",
            nft_mac_dst   = "",
            nft_mac_src   = "",
            nft_ethertype = "",
            nft_src       = "",
            nft_dst       = "",
            nft_proto     = "",
            nft_spt       = "",
            nft_dpt       = "",
          }
        }
      }
    }

    // Push to Loki on the server over the LAN.
    loki.write "server" {
      ${endpoints}
    }
  '';
}
