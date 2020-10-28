{ ... }:

let
  secrets = import ./lib/secrets.nix;
  vars = import ./lib/vars.nix;

in {
  services.traefik = {
    enable = true;

    staticConfigOptions = {
      certificatesResolvers.letsencrypt.acme = {
        email = "mdlayher@gmail.com";
        storage = "/var/lib/traefik/acme.json";
        httpChallenge.entryPoint = "http";
      };

      entryPoints = {
        # External entry points.
        http = {
          address = ":80";
          http.redirections.entryPoint = {
            to = "https";
            scheme = "https";
          };
        };
        https.address = ":443";
      };
    };

    dynamicConfigOptions = {
      http = {
        routers = {
          alertmanager = {
            rule = "Host(`alertmanager.servnerr.com`)";
            middlewares = [ "alertmanager" ];
            service = "alertmanager";
            tls.certResolver = "letsencrypt";
          };

          grafana = {
            rule = "Host(`grafana.servnerr.com`)";
            service = "grafana";
            tls.certResolver = "letsencrypt";
          };

          plex = {
            rule = "Host(`plex.servnerr.com`)";
            service = "plex";
            tls.certResolver = "letsencrypt";
          };

          prometheus = {
            rule = "Host(`prometheus.servnerr.com`)";
            middlewares = [ "prometheus" ];
            service = "prometheus";
            tls.certResolver = "letsencrypt";
          };
        };

        middlewares = {
          alertmanager.basicAuth.users =
            [ "${secrets.traefik.alertmanager_auth}" ];
          prometheus.basicAuth.users = [ "${secrets.traefik.prometheus_auth}" ];
        };

        services = {
          alertmanager.loadBalancer.servers =
            [{ url = "http://servnerr-3.${vars.domain}:9093"; }];
          grafana.loadBalancer.servers =
            [{ url = "http://servnerr-3.${vars.domain}:3000"; }];
          plex.loadBalancer.servers =
            [{ url = "http://servnerr-3.${vars.domain}:32400"; }];
          prometheus.loadBalancer.servers =
            [{ url = "http://servnerr-3.${vars.domain}:9090"; }];
        };
      };
    };
  };
}
