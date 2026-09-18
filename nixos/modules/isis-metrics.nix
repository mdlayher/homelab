# Exports the IGP's adjacency state and protocol counters to Prometheus,
# through node_exporter's textfile collector. frr_exporter collects BGP,
# OSPF, BFD, PIM and VRRP; its binary does not contain the string "isis",
# so without this the only IS-IS signal is frr_route_rib_count's isis
# route_type, which is a proxy for the adjacency and disappears rather
# than reaching zero when the circuit drops.
#
# The adjacency gauge is rendered from the configured links, not from what
# isisd reports: a lost adjacency leaves no entry in the JSON at all, so a
# series built only from isisd's output would vanish exactly when it
# matters. Every link here always has a row, and the row reads 0 when
# isisd does not report the adjacency Up, including when isisd is down.
#
# The PDU counters are the other half. Hellos sent with none received is
# what a carrier that passes no traffic looks like from the protocol's
# side, and reading it from the interface byte counters cannot tell an
# IS-IS packet from anything else sharing the link.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.homelab.interconnect;

  vtysh = "${pkgs.frr}/bin/vtysh";
  jq = "${pkgs.jq}/bin/jq";

  # The circuits this router is configured to run the protocol on, which is
  # what the adjacency rows are generated from. far is the link's far site
  # rather than its attribute name, which is a label and carries the plane:
  # two circuits to one site must agree on the site they reach, or
  # nothing can pair up the two ends of a link.
  links = lib.mapAttrsToList (_: link: {
    inherit (link) interface;
    far = link.site;
  }) cfg.links;

  # A configured circuit with no matching adjacency reads 0; one isisd
  # reports in any state other than Up reads 0 as well. Flaps come from
  # isisd alone, so that row appears only while an adjacency exists.
  adjacency = ''
    [ (.areas // [])[] | (.circuits // [])[]
      | select(.adj != null)
      | {
          iface: .interface.name,
          up: (if .interface.state == "Up" then 1 else 0 end),
          flaps: (.interface["adj-flaps"] // 0),
        }
    ] as $adj
    | $links[]
    | . as $l
    | ($adj | map(select(.iface == $l.interface)) | first) as $a
    | "homelab_isis_adjacency_up{interface=\"\($l.interface)\",far=\"\($l.far)\"} \($a.up // 0)",
      (if $a == null then empty else
        "homelab_isis_adjacency_flaps_total{interface=\"\($l.interface)\",far=\"\($l.far)\"} \($a.flaps)"
      end)
  '';

  summary = ''
    (.vrfs // [])[] | (.areas // [])[]
    | ((.["tx-pdu-type"] // {}) | to_entries[]
       | "homelab_isis_pdu_tx_total{type=\"\(.key)\"} \(.value)"),
      ((.["rx-pdu-type"] // {}) | to_entries[]
       | "homelab_isis_pdu_rx_total{type=\"\(.key)\"} \(.value)"),
      ((.levels // [])[]
       | "homelab_isis_spf_runs_total{level=\"\(.id)\"} \(.["last-run-count"] // 0)")
  '';

  database = ''
    (.areas // [])[] | (.levels // [])[]
    | "homelab_isis_lsps{level=\"\(.id)\"} \(.count // 0)"
  '';
in
lib.mkIf cfg.isis.enable {
  systemd = {
    timers.isis-metrics = {
      description = "Sample IS-IS state for Prometheus";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "1m";
        OnUnitActiveSec = "1m";
      };
    };

    services.isis-metrics = {
      description = "IS-IS metrics for node_exporter";

      serviceConfig = {
        Type = "oneshot";

        # vtysh reads FRR's sockets, which are owned by frr:frrvty. This
        # runs as root, which the textfile directory requires, so the
        # membership is what keeps it working if it ever stops doing so.
        SupplementaryGroups = [ "frrvty" ];
      };

      # Renamed into place so a scrape never sees half a file. Unlike the
      # neighbor table a failed run does not leave the last good file: an
      # adjacency which cannot be read is reported down, and ask() yields
      # an empty object so every jq program below still renders its rows.
      script = ''
        out=${config.homelab.textfileDir}/isis.prom

        ask() {
          local json
          json=$(${vtysh} -c "$1" 2>/dev/null) || json=""
          if [ -z "$json" ] || ! printf '%s' "$json" | ${jq} -e . >/dev/null 2>&1; then
            json='{}'
          fi
          printf '%s' "$json"
        }

        {
          echo "# HELP homelab_isis_adjacency_up Whether isisd reports this circuit's adjacency Up; 0 when it does not, including when isisd is down."
          echo "# TYPE homelab_isis_adjacency_up gauge"
          echo "# HELP homelab_isis_adjacency_flaps_total Adjacency transitions isisd has counted on this circuit since it started."
          echo "# TYPE homelab_isis_adjacency_flaps_total counter"
          ask 'show isis neighbor detail json' \
            | ${jq} -r --argjson links ${lib.escapeShellArg (builtins.toJSON links)} \
                ${lib.escapeShellArg adjacency}

          echo "# HELP homelab_isis_pdu_tx_total IS-IS protocol data units sent, by type."
          echo "# TYPE homelab_isis_pdu_tx_total counter"
          echo "# HELP homelab_isis_pdu_rx_total IS-IS protocol data units received, by type."
          echo "# TYPE homelab_isis_pdu_rx_total counter"
          echo "# HELP homelab_isis_spf_runs_total Shortest path calculations run at this level."
          echo "# TYPE homelab_isis_spf_runs_total counter"
          ask 'show isis summary json' | ${jq} -r ${lib.escapeShellArg summary}

          echo "# HELP homelab_isis_lsps Link state PDUs in the database at this level, this router's own included."
          echo "# TYPE homelab_isis_lsps gauge"
          ask 'show isis database json' | ${jq} -r ${lib.escapeShellArg database}
        } > "$out.tmp"

        mv "$out.tmp" "$out"
      '';
    };
  };
}
