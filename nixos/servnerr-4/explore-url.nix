# A Grafana Explore link running a LogQL query against Loki over the last few
# hours, for alert annotations that should lead straight to the lines behind a
# count. The query holds a "__host__" placeholder, swapped for the rule's
# label template after URL encoding so the braces survive.
#
# Shared because the alerts which want such a link are split across two rule
# sets: Loki's own ruler in nixos/servnerr-4/loki.nix, and the Prometheus
# rules in nixos/servnerr-4/prometheus-alerts.nix, which alert on what that
# ruler records.
{ lib, tailnetDomain }:

expr:
let
  panes = builtins.toJSON {
    a = {
      datasource = "loki";
      queries = [
        {
          refId = "A";
          inherit expr;
          datasource = {
            type = "loki";
            uid = "loki";
          };
        }
      ];
      range = {
        from = "now-3h";
        to = "now";
      };
    };
  };
in
lib.replaceStrings [ "__host__" ] [ "{{ $labels.host }}" ] (
  "https://grafana.${tailnetDomain}/explore?schemaVersion=1&orgId=1&panes=" + lib.escapeURL panes
)
