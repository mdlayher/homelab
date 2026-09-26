{
  config,
  lib,
  ...
}:

# This machine's attachment to the IGP. It terminates no circuit to another
# site; it runs the protocol so the resolver it holds an anycast address for
# can be found, and withdrawn, the same way every other node's is.

let
  inventory = config.homelab.inventory;

  # This site's link between its own routers, from the inventory: each end
  # reads its own addresses and the far end's out of the one registry.
  siteLink = inventory.siteLinks.${config.homelab.site};
  ours = siteLink.${config.networking.hostName};
  far = lib.head (lib.attrValues (lib.filterAttrs (n: _: n != config.networking.hostName) siteLink));
in
{
  imports = [ ../modules/interconnect.nix ];

  config = {
    homelab.interconnect = {
      # The link to this site's router, matching the far end's declaration
      # (nixos/routnerr-3/interconnect.nix). A link of its own rather than
      # the management LAN: a circuit advertises the prefixes on its
      # interface, and a LAN's are a secret subnet and a delegated GUA that
      # renumbers.
      links.router0 = {
        site = config.homelab.site;
        carrier = null;
        interface = ours.interface;
        localAddress = "${ours.carrier}/127";
        remoteAddress = far.carrier;
        localCircuitAddress6 = "${ours.circuit6}/127";
        localCircuitAddress4 = "${ours.circuit4}/31";
        localLla = ours.lla;
        lla = far.lla;
        # The segment's 1500 less the GRETAP's 66. The module's default is
        # sized for a WireGuard carrier, which this link has none of.
        mtu = 1434;
      };

      isis = {
        enable = true;

        # Level 1 only, inside this site's area: the router carries the
        # site to the backbone, and this machine learns nothing from it.
        # It reaches every other site by its default over mgmt0.
        isType = "level-1";

        # The router sets the attached bit on its level-1 LSP, which would
        # install a default over the circuit ahead of the one over mgmt0.
        ignoreAttachedBit = true;

        # No aggregate: the site's prefix is originated by the router, and a
        # second copy of it here would be a second door into the same
        # prefix. What this machine puts into the IGP is the anycast address
        # it answers at, which nixos/modules/anycast.nix advertises for as
        # long as the service behind it runs.

        # The router's level-1 LSP carries every prefix on its
        # interfaces, the passive ones included, whatever their circuit
        # type. Its dn42 addresses and the dn42 VLAN's prefixes are among
        # them; this machine's dn42 address sits on that VLAN, and the
        # IGP's routes would pull that traffic onto the circuit, sourced
        # from the circuit address, into the router's drop. So our dn42
        # space is denied with everything beneath it, written as
        # networking.nix writes it.
        kernelDeny6 = [ "${inventory.dn42.net6} le 128" ];
        kernelDeny4 = [ "${inventory.dn42.net4} le 32" ];
      };
    };

    # Replies sourced from an anycast address or the loopback leave over
    # the circuit. The router routes those addresses at this machine
    # through the circuit, and its anti-spoof check drops a packet
    # arriving on the management LAN whose source it would route
    # elsewhere; this machine learns no route to another site from the
    # IGP, so its default over that LAN is where they would otherwise go.
    # Found for anycast when the router's resolver stopped on 2026-09-21
    # and every answer this machine gave in its place was dropped; the
    # loopback is what the edges forward queries to.
    systemd.network.networks."45-${ours.interface}" =
      let
        table = 300;
        anycast = lib.concatMap (s: [ s.address6 ] ++ lib.optional (s.address4 != null) s.address4) (
          lib.attrValues config.homelab.anycast.services
        );
        loopback = inventory.loopbacks.${config.networking.hostName};
      in
      {
        routes = [
          {
            Destination = "::/0";
            Gateway = far.circuit6;
            Table = table;
          }
          {
            Destination = "0.0.0.0/0";
            Gateway = far.circuit4;
            Table = table;
          }
        ];
        routingPolicyRules = map (address: {
          From = address;
          Table = table;
          Priority = 100;
        }) (anycast ++ [ loopback.addr6 ] ++ lib.optional (loopback.addr4 != null) loopback.addr4);
      };
  };
}
