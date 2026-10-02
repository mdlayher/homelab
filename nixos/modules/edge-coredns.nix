{
  config,
  lib,
  pkgs,
  ...
}:

# The resolver at an edge site, answering the anycast address alongside the
# other nodes holding it (see modules/anycast.nix). A client reaches
# whichever node the IGP says is nearest, so every node has to answer alike
# or the answer depends on where the client happens to be.
#
# What this node can answer by itself is what is plain data: the loopback
# names every site publishes. A site's host records are built from that
# site's inventory secrets, and this machine is handed none of them, so
# everything else is forwarded by unicast to the loopbacks of the resolvers
# at the router's site -- never to the anycast address, which would forward
# this node to itself.
#
# Recursion goes to the same clearnet resolvers azo uses rather than to the
# VPC's, for the same reason: an answer must not depend on which node took
# the query. This machine's own clearnet names still go to the VPC resolver;
# resolved routes only the internal domains here (see configuration.nix).

let
  inventory = config.homelab.inventory;

  # The resolvers which hold everything this one does not: the loopbacks of
  # the machines at the router's site which answer the internal zones, the
  # router and the server, reached across the circuit. Both render those
  # zones from the same inventory, so either answers alike, and naming both
  # keeps this site's names resolving while one of them is down.
  resolvers = lib.concatMapStringsSep " " (n: inventory.sites.azo.loopbacks.${n}.addr6) (
    lib.filter (n: inventory.sites.azo.loopbacks ? ${n}) (
      inventory.roles.router ++ inventory.roles.server
    )
  );

  # This node's listeners. The anycast address is bound before it exists,
  # which the sysctl below permits: it appears only once this service is up,
  # and binding it is how this service comes up.
  loopback = inventory.loopbacks.${config.networking.hostName};
  listen = "${inventory.anycast6.dns} ${loopback.addr6} ${inventory.anycast4.dns} ${loopback.addr4}";

  # A loopback answers the fixed site name every one of them carries, and
  # its own name where the machine is published at it, as the router renders
  # them. Plain data from the inventory, hence a store path.
  loopbackForward =
    lo:
    lib.optionalString (lo.siteFqdn != null) "${lo.addr6} ${lo.siteFqdn}\n"
    + lib.optionalString (lo.fqdn != null) "${lo.addr6} ${lo.fqdn}\n";

  loopbacksFile = pkgs.writeText "coredns-loopbacks" (
    lib.concatMapStrings (site: lib.concatMapStrings loopbackForward (lib.attrValues site.loopbacks)) (
      lib.attrValues inventory.sites
    )
  );

  # Everything the router answers and the clearnet does not. The reverse
  # zones are the whole ULA and the RFC 1918 space including dn42's, which
  # the router splits between its own inventory and dn42's resolvers.
  zones = lib.concatStringsSep " " (
    lib.mapAttrsToList (_: site: site.domain) inventory.sites
    ++ [
      "svc.${inventory.zone}"
      "dn42"
      "d.f.ip6.arpa"
      "10.in-addr.arpa"
    ]
    ++ map (n: "${toString n}.172.in-addr.arpa") (lib.range 16 31)
  );
in
{
  homelab.anycast.services.dns.unit = "coredns.service";

  # Bind an address this machine does not hold. The anycast address is added
  # once this service is running and removed when it stops, so the service
  # which makes the address local cannot wait for it. resolved keeps its own
  # stub on 127.0.0.53, which is why the listeners are named rather than
  # left to the wildcard.
  boot.kernel.sysctl = {
    "net.ipv6.ip_nonlocal_bind" = 1;
    "net.ipv4.ip_nonlocal_bind" = 1;
  };

  services.coredns = {
    enable = true;
    config = ''
      # Root zone. The forwarders are azo's, so recursion here and recursion
      # there give the same answer.
      . {
        bind ${listen}
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

      # Internal names: the loopbacks from the inventory, and the resolvers
      # at the router's site for the rest. The hosts plugin keeps only the
      # names inside this block's zones and falls through for the others.
      ${zones} {
        bind ${listen}
        prometheus :9153
        hosts ${loopbacksFile} {
          fallthrough
        }
        forward . ${resolvers}
      }
    '';
  };
}
