# An RTR cache of the dn42 ROAs: rtrtr fetches burble's JSON export of the
# registry's ROAs and serves it over RTR, published as rtr.svc. The BIRD
# nodes keep their own sessions to the RTR feeds and add this one (see
# dn42.nix), so a node whose own path to the feeds breaks still has ROAs
# while it can reach the server, over the LAN or, from another site, the
# interconnect; the router admits it in iclServices.
#
# rtrtr's RTR client opens at protocol version 2 and the feeds answer only
# version 1, closing the connection on the version error before the client
# retries, so rtrtr cannot take the RTR feeds themselves.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.homelab.rtrCache;

  configFile = (pkgs.formats.toml { }).generate "rtrtr.conf" {
    log_level = "info";
    log_target = "stderr";
    http-listen = [ "127.0.0.1:8323" ];
    units.burble = {
      type = "json";
      uri = "https://dn42.burble.com/roa/dn42_roa_46.json";
      refresh = 600;
    };
    targets.rtr = {
      type = "rtr";
      listen = [ "[::]:${toString cfg.port}" ];
      unit = "burble";
    };
  };
in
{
  options.homelab.rtrCache = {
    enable = lib.mkEnableOption "the dn42 RTR cache";

    port = lib.mkOption {
      type = lib.types.port;
      readOnly = true;
      default = 8282;
      description = "The port the cache serves RTR on.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.rtrtr = {
      description = "RTR cache of the dn42 ROA feeds";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        ExecStart = "${pkgs.rtrtr}/bin/rtrtr --config ${configFile}";
        DynamicUser = true;
        Restart = "on-failure";
      };
    };
  };
}
