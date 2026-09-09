{
  config,
  lib,
  pkgs,
  ...
}:

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

  # Private zones: answered NXDOMAIN here, never forwarded or logged. The
  # names are an inventory secret, so the block is rendered rather than
  # written into the Corefile, and carries neither log nor prometheus, which
  # both label their output with the zone. The file plugin rather than
  # template for the same reason: template's match counter is zone-labelled
  # and served by the root zone's endpoint regardless. The zone file uses
  # relative names only, so one file serves every zone without naming any.
  privateZonesCredential = "private-zones";
  privateZonesFile = ''
    ${inventory.privateZones} {
      file ${pkgs.writeText "coredns-private.zone" ''
        $TTL 3600
        @ IN SOA ns hostmaster 1 7200 3600 1209600 3600
      ''}
    }
  '';
in
{
  sops.templates = {
    "coredns-hosts" = {
      content = hostsFile + servicesFile;
      restartUnits = [ "coredns.service" ];
    };
    "coredns-private-zones" = {
      content = privateZonesFile;
      restartUnits = [ "coredns.service" ];
    };
  };

  # coredns runs with DynamicUser, so hand it the rendered files via systemd
  # credentials.
  systemd.services.coredns.serviceConfig.LoadCredential = [
    "${credential}:${config.sops.templates."coredns-hosts".path}"
    "${privateZonesCredential}:${config.sops.templates."coredns-private-zones".path}"
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

      # Private zones, a server block rendered from the inventory secrets.
      import /run/credentials/coredns.service/${privateZonesCredential}

      # dn42: the forwarders in the root block are on the internet, where
      # no dn42 name exists. Names under dn42 go to its anycast resolvers
      # instead, a0 and a3 of recursive-servers.dn42, which the router
      # reaches from its own dn42 address. For the machines with a dn42
      # interface, the router itself and the development container behind
      # it, both of which resolve through here; any other LAN client that
      # asks gets a name it cannot reach, since the LANs are not routed
      # into dn42.
      dn42 {
        forward . 172.20.0.53 172.23.0.53 fd42:d42:d42:54::1 fd42:d42:d42:53::1
      }
    '';
  };
}
