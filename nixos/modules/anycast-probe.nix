# A DNS probe of the anycast resolver address from a LAN client's vantage.
# Every node holding the address would answer its own probe, so this runs
# on a machine that holds none and speaks no IGP: its query follows the
# router's routing the way any client's does, including across the circuit
# to another holder once the router's own copy is withdrawn. The server
# scrapes it (see nixos/servnerr-4/prometheus.nix) and alerts on a query
# that goes unanswered, which the 2026-09-21 withdrawal exercise showed can
# happen while every holder reports healthy.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  inventory = config.homelab.inventory;

  # The site's own name, as every holder answers it: the edges serve the
  # site loopback names from the inventory without forwarding.
  site = lib.findFirst (lo: lo.siteFqdn != null) null (
    lib.attrValues inventory.sites.${config.homelab.site}.loopbacks
  );
in
{
  assertions = [
    {
      assertion = !(config.homelab ? anycast) || config.homelab.anycast.services == { };
      message = "the anycast probe must run on a machine holding no anycast address";
    }
    {
      assertion = site != null;
      message = "the anycast probe needs a site loopback name to query";
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
            query_name = site.siteFqdn;
            query_type = "AAAA";
            valid_rcodes = [ "NOERROR" ];
            validate_answer_rrs.fail_if_none_matches_regexp = [ ".*\tAAAA\t.*" ];
          };
        };
      }
    );
  };
}
