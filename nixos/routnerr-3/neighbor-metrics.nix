# Exports the router's neighbor table to Prometheus as an info metric,
# through node_exporter's textfile collector, so nftables accounting series
# carrying only an address can be joined to the MAC behind it. The
# companion to homelab_device_info (the server's inventory-metrics.nix),
# which names only what the inventory knows.
#
#   sum by (device, address) (increase(nftables_set_element_bytes_total{set=~"host._wan_in"}[24h]))
#     * on (device, address) group_left (mac)
#       max by (device, address, mac) (last_over_time(homelab_neighbor_info[24h]))
#
# last_over_time over the accounting window: an entry lives only as long as
# its address, and the ones worth naming are IPv6 temporaries that have
# since rotated out. Chain homelab_device_info on mac for a name.
#
# Not the DHCP leases, whose client hostname would be richer: DHCP here is
# IPv4 only, so no lease has seen the SLAAC addresses carrying IPv6 traffic.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  ip = "${pkgs.iproute2}/bin/ip";
  jq = "${pkgs.jq}/bin/jq";

  # Link-local never crosses the WAN and FAILED/INCOMPLETE carry no
  # mapping; dropping them is also what bounds cardinality, which is why
  # network-snapshot.nix keeps the whole table in Loki instead. No
  # canonicalisation: the kernel prints IPv6 in the RFC 5952 form the
  # nftables exporter's keys use.
  program = ''
    [ .[]
      | select(.lladdr)
      | select(.dst | startswith("fe80:") | not)
      | select(.state | index("FAILED") == null and index("INCOMPLETE") == null)
      | "homelab_neighbor_info{address=\"\(.dst)\",device=\"\(.dev)\",mac=\"\(.lladdr)\"} 1"
    ] | unique | .[]
  '';
in
{
  systemd = {
    timers.neighbor-metrics = {
      description = "Sample router neighbor table for Prometheus";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "1m";
        OnUnitActiveSec = "1m";
      };
    };

    services.neighbor-metrics = {
      description = "Neighbor table metrics for node_exporter";
      serviceConfig.Type = "oneshot";

      # Renamed into place so a scrape never sees half a file, and a
      # failed run leaves the last good one: .prom.tmp is outside the glob.
      script = ''
        out=${config.homelab.textfileDir}/neighbor.prom

        {
          echo "# HELP homelab_neighbor_info An address in the router's neighbor table, by hardware address and VLAN; always 1."
          echo "# TYPE homelab_neighbor_info gauge"
          ${ip} -json neigh show | ${jq} -r ${lib.escapeShellArg program}
        } > "$out.tmp"

        mv "$out.tmp" "$out"
      '';
    };
  };
}
