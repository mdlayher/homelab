{ ... }:

# This site's dn42 presence: its own address on dn42, the table over the
# interconnect, and the peers arranged here. The module owns the machinery;
# what is true of this site alone is here.
{
  imports = [ ../modules/dn42.nix ];

  config = {
    # This site's addresses, drawn as the router's are: the IPv4 from the
    # pool of routed /32s, the IPv6 from site 00's loopback /64 with the
    # site and router digits the ULA loopback uses. Both ride the IGP.
    homelab.dn42.addr4 = "172.20.140.85";
    homelab.dn42.addr6 = "fde4:d0ad:ee0f::201";

    # This site's WireGuard public key; the private half is the secret
    # dn42/wireguard_key in this host's secrets file. A peer names this
    # literally as its tunnel peer.
    homelab.dn42.publicKey = "s+gjvLTOg3NRx4zBGigRGt2jLc6UBzwpn3z2Yzmx0BA=";
    homelab.dn42.secretsFile = ./secrets.yaml;

    # The dn42 table over every circuit, one session per plane; each name
    # is a link in interconnect.nix.
    homelab.dn42.ibgp = [
      "azo0"
      "azo1"
      "iad0"
    ];

    # sidereal: https://sidereal.ca, phx1 node.
    homelab.dn42.peers.sidereal = {
      asn = 4242422016;
      publicKey = "3hy0FIf64sxSVLY6/CwhtMfCmQEkG5hsyKxM/Dttvz0=";
      endpoint = "phx1.dn42.sidereal.ca:23610";
      port = 22016;
      lla = "fe80::2016";
    };
  };
}
