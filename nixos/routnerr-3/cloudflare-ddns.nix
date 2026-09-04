# Dynamic DNS for the public names that point at the house.
#
# These addresses are observations of the current world, not decisions someone
# made, so they are owned here rather than in terraform/cloudflare/, which
# manages the records whose values were chosen. Nothing is declared twice: the
# terraform module deliberately omits every A and AAAA record below.
#
# This belongs on the router because the names describe WAN addresses the
# router holds, not addresses of any host behind it.
#
# Both zones carry the same structure, so a name means the same thing under
# either, for <zone> in servnerr.com and mdlayher.net:
#
#   <zone>                  A and AAAA, the WAN currently egressing
#   ipv4.<zone>             the WAN currently egressing, v4
#   ipv6.<zone>             the WAN currently egressing, v6
#   metronet.ipv4.<zone>    wan1, whichever WAN is primary
#   spectrum.ipv4.<zone>    wan0, whichever WAN is primary
#   spectrum.ipv6.<zone>    wan0, whichever WAN is primary
#
# The per-WAN names keep a specific WAN addressable by name during a failover,
# which is when reaching the other one matters. metronet.ipv4 is its own A
# record rather than an alias of ipv4.servnerr.com: an alias would follow a
# failover onto the Spectrum address and stop being true.
#
# The two families egress differently, and that is deliberate rather than a
# mistake to fix: v4 prefers wan1 on route metric, while wan0 holds the only
# IPv6 default route. So an apex answers A from Metronet and AAAA from
# Spectrum. There is no metronet.ipv6 name because Metronet provides no IPv6 —
# wan1 carries a link-local address and nothing else — so the wan1 updater
# below runs v4 only rather than publishing an empty record.
#
# Address selection needs no special care here: neither WAN carries RFC 4941
# temporary addresses. wan0's global v6 is a DHCPv6 /128 rather than a SLAAC
# prefix, so no temporary is ever derived from it, and networkd handles RA in
# userspace with the kernel's accept_ra off, which is why the kernel's
# use_tempaddr = 2 on both WANs has nothing to act on. Should Spectrum ever
# start advertising a SLAAC prefix instead, revisit this: detection would then
# have a rotating privacy address to choose from.
{ config, lib, ... }:

let
  cfg = config.services.cloudflare-ddns;

  # Scoped to DNS:Edit on these two zones only. Distinct from the token in
  # secrets/cloudflare.yaml, which only the development container's secrets
  # gate holds: this one is decrypted onto the router at activation, so a
  # different exposure deserves a separately revocable credential.
  secret = "cloudflare/ddns_token";

  comment = what: "dynamic; ${what}, from cloudflare-ddns on the router";

  # The zones sharing the structure above, and the names it produces. Deriving
  # them keeps the two zones identical by construction rather than by two lists
  # someone has to remember to edit together.
  zones = [
    "servnerr.com"
    "mdlayher.net"
  ];
  names = prefix: map (zone: "${prefix}.${zone}") zones;

  # The upstream module defines exactly one instance, and an instance has one
  # provider per family, so a name tracking a specific interface needs a unit
  # of its own. These reuse the packaged unit's serviceConfig, and so its
  # user, token, ExecStart and hardening, replacing only the environment.
  wanUpdater =
    iface:
    {
      ip4,
      ip6 ? [ ],
    }:
    {
      description = "Cloudflare dynamic DNS for ${iface}";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      serviceConfig = config.systemd.services.cloudflare-ddns.serviceConfig // {
        Environment = [
          ''IP4_DOMAINS="${lib.concatStringsSep "," ip4}"''
          ''IP4_PROVIDER="local.iface:${iface}"''
          ''TTL="1"''
          ''RECORD_COMMENT="${comment iface}"''
        ]
        ++ (
          if ip6 == [ ] then
            [ ''IP6_PROVIDER="none"'' ]
          else
            [
              ''IP6_DOMAINS="${lib.concatStringsSep "," ip6}"''
              ''IP6_PROVIDER="local.iface:${iface}"''
            ]
        );

        # local.iface enumerates interfaces over netlink, which the packaged
        # unit's address family restriction does not allow for; the default
        # provider never opens such a socket, so upstream has no reason to.
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_NETLINK"
        ];
      };
    };
in
{
  sops.secrets.${secret}.sopsFile = ./secrets.yaml;

  # The updater takes its token through an EnvironmentFile, so the secret is
  # rendered as KEY=value rather than handed over bare. Every unit shares it.
  sops.templates."cloudflare-ddns.env" = {
    content = ''
      CLOUDFLARE_API_TOKEN=${config.sops.placeholder.${secret}}
    '';
    owner = cfg.user;
    restartUnits = [
      "cloudflare-ddns.service"
      "cloudflare-ddns-wan0.service"
      "cloudflare-ddns-wan1.service"
    ];
  };

  # Both providers default to cloudflare.trace, which reports the address a
  # Cloudflare endpoint sees — per family, so this follows a failover.
  services.cloudflare-ddns = {
    enable = true;
    credentialsFile = config.sops.templates."cloudflare-ddns.env".path;

    domains = zones;
    ip4Domains = names "ipv4";
    ip6Domains = names "ipv6";

    # Cloudflare's automatic TTL, matching terraform/cloudflare. Records stay
    # DNS-only, which is this module's default for proxied.
    ttl = 1;

    # Marks these in the dashboard, so which records terraform does not manage
    # is obvious without cross-referencing this file.
    recordComment = comment "current egress";
  };

  systemd.services = {
    cloudflare-ddns-wan0 = wanUpdater "wan0" {
      ip4 = names "spectrum.ipv4";
      ip6 = names "spectrum.ipv6";
    };
    cloudflare-ddns-wan1 = wanUpdater "wan1" {
      ip4 = names "metronet.ipv4";
    };
  };
}
