{ config, lib, ... }:

let
  inventory = config.homelab.inventory;

  # Internal DNS records for each host and the router itself, as a hosts file
  # rendered from the inventory secrets. Hosts without a known IPv6 address get
  # an A record only.
  hostsFile = lib.concatMapStrings (
    host:
    ''
      ${host.ipv4} ${host.name}.${inventory.domain}
      ${host.ipv4} ${host.name}.ipv4.${inventory.domain}
    ''
    + lib.optionalString (host.ula != null) ''
      ${host.ula} ${host.name}.${inventory.domain}
      ${host.ula} ${host.name}.ipv6.${inventory.domain}
    ''
  ) (lib.attrValues inventory.hosts ++ [ router ]);

  router = {
    name = config.networking.hostName;
    inherit (inventory.interfaces.lan0) ipv4 ula;
  };

  credential = "hosts";
in
{
  sops.templates."coredns-hosts" = {
    content = hostsFile;
    restartUnits = [ "coredns.service" ];
  };

  # coredns runs with DynamicUser, so hand it the hosts file via systemd
  # credentials.
  systemd.services.coredns.serviceConfig.LoadCredential = [
    "${credential}:${config.sops.templates."coredns-hosts".path}"
  ];

  services.coredns = {
    enable = true;
    config = ''
      # Root zone.
      . {
        cache 3600 {
          success 8192
          denial 4096
        }
        prometheus :9153
        forward . tls://8.8.8.8 tls://8.8.4.4 tls://2001:4860:4860::8888 tls://2001:4860:4860::8844 {
          tls_servername dns.google
          health_check 5s
        }
      }

      # Internal zone.
      ${inventory.domain} {
        hosts /run/credentials/coredns.service/${credential}
      }
    '';
  };
}
