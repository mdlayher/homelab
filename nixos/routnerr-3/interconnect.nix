{
  config,
  lib,
  ...
}:

# This router's end of each circuit it terminates, to another site and to
# this site's other router. The module (nixos/modules/interconnect.nix) owns
# the shape; this file supplies the addresses, the identity, and what this
# router puts into the IGP.

let
  inventory = config.homelab.inventory;

  # pdx's carrier key, shared by both links to it: one key identifies that
  # router, and the two carriers differ by port rather than by identity.
  pdxPublicKey = "7gO2i3ZxZFosAOuRZgC5yFIM/8fBX+KqVEo/HoWajD8=";
  iadPublicKey = "l//gZ3Af+Cr9QXNFjNdOy4Tl5K5Rl3X9QEnXhxMVf3U=";

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
      # One key for the dn42 tunnels and the carrier both. A separate one
      # keeps the two blast radii apart; this reuses it because the public
      # half is already published and pdx can name it rather than repeat it.
      privateKeyFile = config.sops.secrets."dn42/wireguard_key".path;

      # One carrier per WAN, so a single ISP outage costs one circuit rather
      # than the site. The IGP treats them as any other pair of links and,
      # at equal metrics, uses both.
      #
      # The mark is what makes them independent: without it both carriers
      # follow the main table out whichever WAN it prefers, and the two
      # adjacencies report a redundancy that does not exist. The rules and
      # the per-WAN tables the marks select are in networking.nix, which is
      # where this site's WANs are described.
      #
      # This site dials every link, as the lower index does under the
      # module's rule, which is also what its dynamic WAN addresses require.
      # The endpoints and ports are the module's, derived from the far site
      # and the plane, and the names they resolve are published in
      # terraform/cloudflare.
      #
      # Plane 1 dials the ipv4 name, which pins the address family the mark
      # cannot: Metronet carries no IPv6, so a carrier marked for it with an
      # IPv6 endpoint would be steered correctly and then find no route in
      # that table.
      links.pdx0 = {
        site = "pdx";
        publicKey = pdxPublicKey;
        firewallMark = 1;
      };

      links.pdx1 = {
        site = "pdx";
        plane = 1;
        publicKey = pdxPublicKey;
        endpointFamily = "ipv4";
        firewallMark = 2;
      };

      # The same pair toward iad. The marks repeat because they name a WAN
      # rather than a site: plane 0 leaves by the uplink with IPv6 and plane
      # 1 by the one without, whichever site is at the far end.
      links.iad0 = {
        site = "iad";
        publicKey = iadPublicKey;
        firewallMark = 1;
      };

      links.iad1 = {
        site = "iad";
        plane = 1;
        publicKey = iadPublicKey;
        endpointFamily = "ipv4";
        firewallMark = 2;
      };

      # The second resolver at this site, joined by a link of its own rather
      # than by the management LAN: a circuit advertises the prefixes on its
      # interface, and a LAN's are a secret subnet and a delegated GUA that
      # renumbers. A bare GRETAP carries only its own /127, and both ends
      # already share a segment, so it needs no carrier to cross.
      links.server0 = {
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

      # The landing page at this site's icl names. The per-uplink names are
      # published by cloudflare-ddns.nix and the dial names alias them in
      # terraform/cloudflare; all of them answer here. DNS-01 because each
      # of those is pinned to one uplink, so HTTP-01 could not renew while
      # that uplink was down; the credential is the one dn42-page.nix
      # renders for the same provider.
      page = {
        enable = true;
        extraNames = map (prefix: "${prefix}.${config.homelab.site}.icl.mdlayher.net") [
          "ipv4.spectrum"
          "ipv6.spectrum"
          "ipv4.metronet"
        ];
        acmeEnvironmentFile = config.sops.templates."acme-cloudflare.env".path;
      };

      isis = {
        enable = true;

        # The backbone to the other sites and this site's own area, over
        # the circuit to the server.
        isType = "level-1-2";

        # The whole site in one prefix, so the far end has a route home
        # without this router advertising a LAN. The unreachable aggregate
        # on loopback is the route it matches (see networking.nix); the
        # more specific LANs sort traffic out once it arrives, and anything
        # nobody holds meets the aggregate and is rejected here.
        aggregate6 = inventory.ulaPrefix6;
        # The IPv4 scheme's whole space, on the same terms. The
        # unreachable route it matches is on lo (see networking.nix).
        aggregate4 = [ inventory.privatePrefix4 ];
      };
    };
  };
}
