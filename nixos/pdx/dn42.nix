{ ... }:

# This site's half of dn42. No external peers yet: pdx reaches the dn42
# table through iBGP over the interconnect, so the only BGP session here is
# the one to azo.
#
# The module still originates the aggregates as unreachable statics, which
# is what makes anycast work once this site has peers of its own. Until
# then they go nowhere but the iBGP session, where azo already has them.
{
  imports = [ ../modules/dn42.nix ];

  homelab.dn42 = {
    # Site 02 under the SSVV scheme: /29 172.20.140.88 and /56
    # fde4:d0ad:ee0f:0200::, both internal to our AS and reached over the
    # IGP, so neither appears in the registry. These two are the router's
    # own addresses, from site 00's loopback block.
    addr4 = "172.20.140.89";
    addr6 = "fde4:d0ad:ee0f::2";

    # No dn42 tunnels here, so there is no dn42 key to name. The
    # interconnect carrier has its own, in interconnect.nix.
    publicKey = null;

    # Unused while peers is empty: the module declares dn42/wireguard_key
    # only when a tunnel exists.
    secretsFile = ./secrets.yaml;

    # The dn42 table, over the circuit to azo. ibgpInternal stays at its
    # default until the IGP carries both sites' prefixes; flipping it is
    # the cutover.
    ibgp = [ "azo" ];
  };
}
