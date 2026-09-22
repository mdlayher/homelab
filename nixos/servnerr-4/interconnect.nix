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
        metric = ours.metric;
        # The segment's 1500 less the GRETAP's 66. The module's default is
        # sized for a WireGuard carrier, which this link has none of.
        mtu = 1434;
      };

      isis = {
        enable = true;

        # No aggregate: the site's prefix is originated by the router, and a
        # second copy of it here would be a second door into the same
        # prefix. What this machine puts into the IGP is the anycast address
        # it answers at, which nixos/modules/anycast.nix advertises for as
        # long as the service behind it runs.

        # The router's aggregates for this site arrive over the circuit,
        # and this machine reaches the site's LANs over mgmt0. Installed,
        # the IGP's copy would win on metric and carry LAN-bound traffic
        # across the circuit sourced from the circuit address, which the
        # router's forward_icl drops as a far-site flow; the scrapes of
        # the dev0 containers did exactly that on 2026-09-21. The far
        # sites' prefixes are still installed, since the circuit is the
        # path to those. Our dn42 space on the same terms, written as
        # networking.nix writes it: this machine's dn42 address sits on the
        # router's dn42 VLAN, and the IGP's routes to the router's own dn42
        # addresses would pull that traffic onto the circuit too. Those are
        # host routes from the router's passive dn42 interface, so the
        # allocation is denied with everything beneath it: every dn42
        # node's address, this site's or another's, is reached through
        # the VLAN.
        kernelDeny6 = [
          inventory.ulaPrefix6
          "${inventory.dn42.net6} le 128"
        ];
        kernelDeny4 = [
          inventory.privatePrefix4
          "${inventory.dn42.net4} le 32"
        ];
      };
    };

    # Replies sourced from an anycast address leave over the circuit. The
    # router routes those addresses at this machine through the circuit,
    # and its anti-spoof check drops a packet arriving on the management
    # LAN whose source it would route elsewhere; with the site's prefixes
    # kept out of the kernel above, that LAN is where they would otherwise
    # go. Found when the router's resolver stopped on 2026-09-21 and every
    # answer this machine gave in its place was dropped.
    systemd.network.networks."45-${ours.interface}" =
      let
        table = 300;
        anycast = lib.concatMap (s: [ s.address6 ] ++ lib.optional (s.address4 != null) s.address4) (
          lib.attrValues config.homelab.anycast.services
        );
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
        }) anycast;
      };
  };
}
