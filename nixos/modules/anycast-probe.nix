# A DNS probe of the anycast resolver address from a LAN client's vantage.
# Every node holding the address would answer its own probe, and a node on
# the same segment as a holder is answered directly, so this runs on a
# segment no holder has an interface on: its query and the reply both cross
# the router, the way any client's do, including across the circuit to
# another holder once the router's own copy is withdrawn. The server scrapes
# it (see nixos/servnerr-4/prometheus.nix) and alerts on a query that goes
# unanswered, which the 2026-09-21 withdrawal exercise showed can happen
# while every holder reports healthy.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.homelab.anycastProbe;
in
{
  options.homelab.anycastProbe.queryName = lib.mkOption {
    type = lib.types.str;
    description = ''
      The name to resolve, which every holder must answer from its own data:
      a site loopback name, which the edges serve from the inventory without
      forwarding. Set by whatever declares this host, since a guest holds no
      inventory of its own.
    '';
  };

  config = {
    assertions = [
      {
        assertion = !(config.homelab ? anycast) || config.homelab.anycast.services == { };
        message = "the anycast probe must run on a machine holding no anycast address";
      }
    ];

    services.prometheus.exporters.blackbox = {
      enable = true;
      openFirewall = true;
      configFile = pkgs.writeText "blackbox.yml" (
        builtins.toJSON {
          modules.dns_anycast = {
            prober = "dns";
            dns = {
              query_name = cfg.queryName;
              query_type = "AAAA";
              valid_rcodes = [ "NOERROR" ];
              validate_answer_rrs.fail_if_none_matches_regexp = [ ".*\tAAAA\t.*" ];
            };
          };
        }
      );
    };
  };
}
