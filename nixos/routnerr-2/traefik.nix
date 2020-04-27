{ ... }:

let
  secrets = import ./secrets.nix;
  vars = import ./vars.nix;

in {
  services.traefik = {
    enable = true;

    configOptions = {
      defaultEntrypoints = [ "http" "https" ];

      entryPoints = {
        # External entry points.
        http = {
          address = ":80";
          redirect.entryPoint = "https";
        };
        https = {
          address = ":443";
          tls = { };
        };
        # Internal entry point for debugging.
        traefik.address = ":8080";
      };

      # Enable the web interface and Prometheus metrics.
      api = { };
      metrics.prometheus = { };

      # Required for frontends/backends statements to work.
      file = { };

      backends = {
        alertmanager.servers.alertmanager.url =
          "http://monitnerr-1.${vars.domain}:9093";
        grafana.servers.grafana.url = "http://servnerr-3.${vars.domain}:3000";
        plex.servers.plex.url = "http://servnerr-3.${vars.domain}:32400";
        prometheus.servers.prometheus.url =
          "http://servnerr-3.${vars.domain}:9090";
      };

      frontends = {
        alertmanager = {
          backend = "alertmanager";
          basicAuth = [ "${secrets.traefik.alertmanager_auth}" ];
          routes.alertmanager.rule = "Host:alertmanager.servnerr.com";
        };
        grafana = {
          backend = "grafana";
          routes.grafana.rule = "Host:grafana.servnerr.com";
        };
        plex = {
          backend = "plex";
          routes.plex.rule = "Host:plex.servnerr.com";
        };
        prometheus = {
          backend = "prometheus";
          basicAuth = [ "${secrets.traefik.prometheus_auth}" ];
          routes.prometheus.rule = "Host:prometheus.servnerr.com";
        };
      };

      acme = {
        email = "mdlayher@gmail.com";
        storage = "/var/lib/traefik/acme.json";
        entryPoint = "https";
        httpChallenge.entryPoint = "http";

        domains = [
          {
            main = "servnerr.com";
            sans = [ "www.servnerr.com" ];
          }
          { main = "alertmanager.servnerr.com"; }
          { main = "grafana.servnerr.com"; }
          { main = "plex.servnerr.com"; }
          { main = "prometheus.servnerr.com"; }
        ];
      };
    };
  };
}
