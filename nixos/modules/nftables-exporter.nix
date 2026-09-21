# Prometheus exporter for nftables named counters and per-element set
# counters, read via netlink at scrape time; built from source in this
# repository, since nixpkgs has none. Imported by every machine whose
# ruleset carries a counter worth a graph: the router's accounting and drop
# counters, and each edge's discard counter. The server scrapes it on port
# 9630, per the exporter default port allocations wiki; see
# nixos/servnerr-4/prometheus.nix, which names the hosts.
{ pkgs, ... }:

let
  # Go 1.27 from unstable, matching the toolchain used everywhere else.
  nftables_exporter = (pkgs.buildGoModule.override { go = pkgs.unstable.go_1_27; }) {
    pname = "nftables_exporter";
    version = "0.1.0";
    src = ../../go/internal/nftables_exporter;
    vendorHash = "sha256-IOX2K4bBnhDq88PBU1yOmpZhBa3OXrgIohBBpmv9LZ0=";
  };
in
{
  systemd.services.nftables-exporter = {
    description = "Prometheus nftables exporter";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      ExecStart = "${nftables_exporter}/bin/nftables_exporter";
      Restart = "always";

      # Reading nftables over netlink needs CAP_NET_ADMIN; everything else
      # is locked down.
      DynamicUser = true;
      AmbientCapabilities = [ "CAP_NET_ADMIN" ];
      CapabilityBoundingSet = [ "CAP_NET_ADMIN" ];
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      ProtectKernelTunables = true;
      ProtectControlGroups = true;
      RestrictNamespaces = true;
    };
  };
}
