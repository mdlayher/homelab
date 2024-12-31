{ ... }:

let
  secrets = import ./lib/secrets.nix;
  vars = import ./lib/vars.nix;

in
{
  services.caddy = {
    enable = true;
    virtualHosts = {
      "alertmanager.servnerr.com".extraConfig = ''
        reverse_proxy http://servnerr-4.${vars.domain}:9093
        basicauth {
          ${secrets.caddy.alertmanager_auth}
        } 
      '';

      "grafana.servnerr.com".extraConfig = ''
        reverse_proxy http://servnerr-4.${vars.domain}:3000
      '';

      "plex.servnerr.com".extraConfig = ''
        reverse_proxy http://servnerr-4.${vars.domain}:32400
      '';

      "prometheus.servnerr.com".extraConfig = ''
        reverse_proxy http://servnerr-4.${vars.domain}:9090
        basicauth {
          ${secrets.caddy.prometheus_auth}
        }
      '';
    };
  };
}
