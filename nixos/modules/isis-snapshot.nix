# Periodic snapshots of the IGP's state, written to the journal as JSON and
# shipped to Loki by nixos/modules/alloy.nix, in the shape of the router's
# network snapshot (nixos/routnerr-3/network-snapshot.nix): what each LSP
# carried, which routes isisd computed, and which of them zebra held, at any
# past five-minute mark. The metrics in isis-metrics.nix count these; the
# snapshot says what they were.
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

  # One line per LSP, so a query can select one LSP ID and no line grows
  # with the size of the area. The remaining lifetime is dropped because it
  # ticks down between samples; the sequence number and checksum stay. The
  # authentication TLV is dropped because FRR prints a cleartext password
  # in it as authPass.
  lsp = ''
    (.areas // [])[] | (.levels // [])[] | .id as $level
    | (.lsps // [])[]
    | {level: $level, id: .lsp.id, own: (.lsp.ownLSP // false)}
      + del(.lsp, .holdtime, .testAuth, .authPass, .authHmacMd5, .authUnknown)
    | "kind=isis-lsp \(tojson)"
  '';

  # isisd's routes, one line per family, a row per next hop with its level.
  route = ''
    def rows($afi):
      [ .[] | to_entries[] | select(.key | startswith("level-"))
        | (.key | ltrimstr("level-") | tonumber) as $level
        | (.value[$afi] // [])[]
        | {level: $level, prefix, metric, interface, nextHop} ];
    (rows("ipv4") | select(length > 0) | "kind=isis-route4 \(tojson)"),
    (rows("ipv6") | select(length > 0) | "kind=isis-route6 \(tojson)")
  '';

  # zebra's IS-IS routes, without the uptime and internal identifiers that
  # change between samples. A flag is present only when true.
  rib = ''
    [ to_entries[] | .value[]
      | {prefix, distance, metric}
        + ({selected, installed, failed, queued} | with_entries(select(.value)))
        + {nexthops: [ (.nexthops // [])[]
            | {ip, interfaceName} + ({active, fib} | with_entries(select(.value))) ]} ]
    | select(length > 0)
    | "kind=\($kind) \(tojson)"
  '';
in
lib.mkIf cfg.isis.enable {
  systemd = {
    timers.isis-snapshot = {
      description = "Sample IS-IS state for Loki";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "2m";
        OnUnitActiveSec = "5m";
      };
    };

    services.isis-snapshot = {
      description = "IS-IS state snapshot";
      serviceConfig = {
        Type = "oneshot";
        DynamicUser = true;
        SupplementaryGroups = [ "frrvty" ];
      };

      # Written to stdout for the reasons given in the router's network
      # snapshot. A command that fails or prints something other than JSON
      # yields no line for its kind.
      script = ''
        ask() {
          ${vtysh} -c "$1" 2>/dev/null | ${jq} -c . 2>/dev/null || true
        }

        ask 'show isis database detail json' | ${jq} -r ${lib.escapeShellArg lsp}
        ask 'show isis route json' | ${jq} -r ${lib.escapeShellArg route}
        ask 'show ip route isis json' | ${jq} -r --arg kind isis-rib4 ${lib.escapeShellArg rib}
        ask 'show ipv6 route isis json' | ${jq} -r --arg kind isis-rib6 ${lib.escapeShellArg rib}
      '';
    };
  };
}
