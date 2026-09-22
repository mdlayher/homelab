{ ... }:

# This site's dn42 presence: a host on dn42 with no peers of its own, which
# reaches it over the interconnect through the site that has them. The
# module owns the machinery; what is true of this site alone is here.
{
  imports = [ ../modules/dn42.nix ];

  config = {
    # This site's addresses, drawn as the router's are: the IPv4 from the
    # pool of routed /32s, the IPv6 from site 00's loopback /64 with the
    # site and router digits the ULA loopback uses. Both ride the IGP.
    homelab.dn42.addr4 = "172.20.140.85";
    homelab.dn42.addr6 = "fde4:d0ad:ee0f::201";

    # No tunnels here, so no key of our own to publish. The module requires
    # a secrets file to name the key by; this host's holds none for dn42
    # until a peer is arranged at this site.
    homelab.dn42.publicKey = null;
    homelab.dn42.secretsFile = ./secrets.yaml;

    # The dn42 table over every circuit, one session per plane; each name
    # is a link in interconnect.nix.
    homelab.dn42.ibgp = [
      "azo0"
      "azo1"
      "iad0"
    ];
  };
}
