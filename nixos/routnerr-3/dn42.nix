{ ... }:

# This site's dn42 presence. The protocol machinery, the options and the
# firewall hooks live in the shared module; what stays here is everything
# true of this site alone: the peers we have arranged, and which internal
# links this router carries. A second site imports the same module and
# writes its own version of this file.

{
  imports = [ ../modules/dn42.nix ];

  config = {
    # This site's WireGuard key lives in this host's secrets file; the
    # module has no way to name it (see its secretsFile option).
    homelab.dn42.secretsFile = ./secrets.yaml;

    # Where this router's dn42 services answer, and the ns1 glue the
    # registry publishes; the inventory's iBGP loopback sits beside it.
    homelab.dn42.addr6 = "fde4:d0ad:ee0f::1";

    # This site's WireGuard public key; the private half is the secret named
    # above. The edge names this literally as its carrier peer.
    homelab.dn42.publicKey = "yHaVotqyBwnDqT9mj4t28fFnpLyAGosU3gOq/ngmkHk=";

    # The dn42 table to the other sites, one session per node between
    # loopbacks; the IGP decides which circuit carries it.
    homelab.dn42.ibgp = [
      "edge-pdx"
      "edge-iad"
    ];

    # Kioubit: https://dn42.g-load.eu.
    homelab.dn42.peers.kioubit = {
      asn = 4242423914;
      publicKey = "6Cylr9h1xFduAO+5nyXhFI1XJ0+Sw9jCpCDvcqErF1s=";
      endpoint = "us2.g-load.eu:20060";
      port = 23914;
      lla = "fe80::ade0";
    };

    # highdef: https://highdef.network.
    homelab.dn42.peers.highdef = {
      asn = 4242421080;
      publicKey = "u4WJMAoCHIOeh/+6NWMytNygp+/wrMogB+rwyVzXoEg=";
      endpoint = "chi.peer.highdef.network:23610";
      port = 21080;
      lla = "fe80::113";
    };

    # s6v: https://s6v.net, CHI1 node.
    homelab.dn42.peers.s6v = {
      asn = 4242423432;
      publicKey = "4l7IsOWildZ7icY3N5XPrDtnqYmow4MQgAiF49elBwQ=";
      endpoint = "chi1.dn42.s6v.net:42034";
      port = 23432;
      lla = "fe80::3432";
    };

    # sidereal: https://sidereal.ca, tor1 node.
    homelab.dn42.peers.sidereal = {
      asn = 4242422016;
      publicKey = "5gReh4Xjyp2spGGabBQVUBVS/IGSrIHPMNaMG5AK2Q0=";
      endpoint = "tor1.dn42.sidereal.ca:23610";
      port = 22016;
      lla = "fe80::2016";
    };

    # pixia: buf1 node.
    homelab.dn42.peers.pixia = {
      asn = 4242423729;
      publicKey = "T7o/Vna0wfNAMe8H2VputJdi55V0w+SDZrQvTlLgvjs=";
      endpoint = "buf1.pixiainfra.pixia.eu.org:23610";
      port = 23729;
      lla = "fe80::3729";
    };

    # routedbits: https://routedbits.com, chi1 node. The full name is one
    # character too long for an ifname.
    homelab.dn42.peers.routedbits = {
      interface = "dn42e-routedbit";
      asn = 4242420207;
      publicKey = "89xUzROs3l/KNPLxDTJz4l5aEH1cmLb22bNgChhRiQo=";
      endpoint = "router.chi1.routedbits.com:53610";
      port = 20207;
      lla = "fe80::207";
    };

    # franta: https://dn42.franta.us, us1 node.
    homelab.dn42.peers.franta = {
      asn = 4242421033;
      publicKey = "us1lbET55c+MYkpirulp4BHrLU7rIKqmutcIX9NZ8hY=";
      endpoint = "us1.dn42.franta.us:23610";
      port = 21033;
      lla = "fe80::1033:3610";
    };

    # dn42i-dev0, carrying the session with wipbgpd in the development
    # container. The server bridges the VLAN into the container as its
    # dn42 interface (see the server's networking.nix and dev.nix); the
    # session stays idle until a speaker listens there.
    #
    # The only L2 dn42 segment we have: the tunnels are point to point
    # with no data link of their own, so this is where a protocol that
    # runs on the link itself can be developed against real routes.
    homelab.dn42.vlans.dev0 = {
      vlan = 42;
      net6 = "fde4:d0ad:ee0f:142::/64";
      addr6 = "fde4:d0ad:ee0f:142::1";
      onLink4 = "172.20.140.80/29";
      session = true;
      neighbor = "fde4:d0ad:ee0f:142::10";
      debug = true;
    };
  };
}
