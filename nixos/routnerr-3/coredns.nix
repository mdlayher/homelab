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

  # Stable service names: <service>.svc.<domain> resolves to the primary
  # holder of the service's role, so devices which cannot join the tailnet
  # may hardcode a name that follows the service across hardware generation
  # swaps; see nixos/inventory/default.nix. A name resolves to the primary
  # alone: clients cut over when the role's holder list is reordered, never
  # round-robin across generations.
  servicesFile = lib.concatMapStrings (
    service:
    let
      host = inventory.hosts.${lib.head inventory.roles.${service.value}};
    in
    ''
      ${host.ipv4} ${service.name}.svc.${inventory.domain}
    ''
    + lib.optionalString (host.ula != null) ''
      ${host.ula} ${service.name}.svc.${inventory.domain}
    ''
  ) (lib.attrsToList inventory.services);

  credential = "hosts";
in
{
  sops.templates."coredns-hosts" = {
    content = hostsFile + servicesFile;
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
        # Denials only, never successful lookups: the class covers NXDOMAIN
        # and NODATA, which is the useful half. A device hammering a name
        # that does not resolve, a search domain that never got configured,
        # or an appliance calling home to something that is gone all show up
        # here, at a small fraction of the cost of logging everything. The
        # router answers roughly 1 query per second (see
        # CoreDNSUpstreamFailing), so full query logging would be on the
        # order of 86k lines a day, dwarfing every other journal on this
        # machine - and it would be a browsing history for every device in
        # the house, which is not a thing worth keeping for a year.
        #
        # This block only, not the internal zone below: a name missing from
        # the hosts file is answered SERVFAIL rather than NXDOMAIN, so it is
        # of class error and a log directive there would not see it anyway.
        log . {
          class denial
        }
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
