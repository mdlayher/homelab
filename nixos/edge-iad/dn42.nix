{ ... }:

# This site's dn42 presence: a host on dn42 with no peers of its own, which
# reaches it over the interconnect through the site that has them. The
# module owns the machinery; what is true of this site alone is here.
{
  imports = [ ../modules/dn42.nix ];

  config = {
    # No tunnels here, so no key of our own to publish. The module requires
    # a secrets file to name the key by; this host's holds none for dn42
    # until a peer is arranged at this site.
    homelab.dn42.publicKey = null;
    homelab.dn42.secretsFile = ./secrets.yaml;

    # The dn42 table to the other sites, one session per node between
    # loopbacks; the IGP decides which circuit carries it.
    homelab.dn42.ibgp = [
      "routnerr-3"
      "edge-pdx"
    ];
  };
}
