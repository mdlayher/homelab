# Prometheus exporter for the 3D printer's state, temperatures and current
# job, polled from its PrusaLink API on each scrape; built from source in
# this repository. The server scrapes it on port 9632; see prometheus.nix.
{
  config,
  pkgs,
  ...
}:

let
  inherit (config.homelab) inventory;

  # Go 1.27 from unstable.
  prusa_exporter = (pkgs.buildGoModule.override { go = pkgs.unstable.go_1_27; }) {
    pname = "prusa_exporter";
    version = "0.1.0";
    src = ../../go/internal/prusa_exporter;
    vendorHash = "sha256-RMiv+3ExkjYHJlVW6qDjpmFJbiuaXrXBJLuO8srGuOo=";
  };

  printer = "${inventory.hosts.prusa-core-one.dnsName}.${inventory.domain}";
in
{
  # The PrusaLink password set on the printer, which its API takes as the
  # API key.
  sops.secrets."prusa/prusalink_api_key" = { };
  sops.templates."prusa-exporter.env" = {
    content = ''
      PRUSALINK_API_KEY=${config.sops.placeholder."prusa/prusalink_api_key"}
    '';
    restartUnits = [ "prusa-exporter.service" ];
  };

  systemd.services.prusa-exporter = {
    description = "Prometheus Prusa printer exporter";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      ExecStart = "${prusa_exporter}/bin/prusa_exporter -printer.addr=${printer}";
      EnvironmentFile = config.sops.templates."prusa-exporter.env".path;
      Restart = "always";

      # Polling over HTTP needs no capabilities; everything is locked down.
      DynamicUser = true;
      CapabilityBoundingSet = [ "" ];
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
