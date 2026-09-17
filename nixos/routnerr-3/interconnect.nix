{
  config,
  lib,
  ...
}:

# This site's interconnects: a real circuit to pdx, and a lab one to the
# frrdev container which brought the IGP up before there was a second site.
#
# The lab link is the one with no WireGuard carrier; everything below about
# labPrefix and the carrier-less GRETAP describes it alone.
#
# Both ends are in this site, so the link needs no WireGuard carrier: the
# GRETAP is built straight on two addresses which already reach each other
# over dev0. Everything else is the shape a real interconnect has, the MTU
# included, so what is exercised here is what will run between sites.
#
# All of its addressing comes from the inventory's labPrefix, a /56 of the
# ULA which no subnet uses. Each end advertises one /64 from it into the
# IGP and nothing else: the site's real prefixes stay out, so a route this
# lab installs can never shadow one the LANs depend on.

let
  inventory = config.homelab.inventory;
  isis = inventory.isis;

  # labPrefix is a /56, so its /64s differ in the last two hex digits of the
  # fourth hextet: ff00 the link itself, ff01 ours, ff02 the container's.
  lab = lib.removeSuffix "00::/56" inventory.labPrefix;

  # The first /127 of the interconnect carrier /56; pdx takes ::0.
  carrier = lib.removeSuffix "00::/56" inventory.interconnectPrefix;
  pdxLink = "${carrier}00::";

  link = "${lab}00::";
  ours = "${lab}01::";
  theirs = "${lab}02::";
in
{
  config = {
    homelab.interconnect = {
      # Keyed for the site rather than the far end: a real interconnect is
      # named for the site it reaches, and both ends of this one are in
      # azo, so icl-azo is what matches the dn42 naming.
      # One key for the dn42 tunnels and the carrier both. A separate one
      # keeps the two blast radii apart; this reuses it because the public
      # half is already published and pdx can name it rather than repeat it.
      privateKeyFile = config.sops.secrets."dn42/wireguard_key".path;

      links.pdx = {
        publicKey = "7gO2i3ZxZFosAOuRZgC5yFIM/8fBX+KqVEo/HoWajD8=";
        port = 51821;

        # We initiate, because this WAN address is dynamic and pdx's is not.
        # The name is where pdx's addresses are written down, in
        # terraform/cloudflare; networkd resolves it.
        endpoint = "pdx.dn42.mdlayher.net:51821";

        localAddress = "${pdxLink}1/127";
        remoteAddress = "${pdxLink}";
        localLla = "fe80::1";
        lla = "fe80::2";
      };

      links.azo = {
        # No carrier: see the header. The GRETAP's local address must be a
        # local address, so the module does not create it and dev0 carries
        # it below.
        carrier = null;
        localAddress = "${link}1/127";
        remoteAddress = "${link}";
        localLla = "fe80::1";
        lla = "fe80::11";
      };

      isis = {
        enable = true;
        # Area and system ID come from the inventory, which explains the
        # scheme and is the registry for both; the NSAP selector is always
        # 00 for a router's own NET.
        net = "${isis.area}.${isis.systemIds.routnerr-3}.00";
        # What this router puts into the IGP beyond the circuits themselves.
        #
        # "dn42" is the dummy holding this router's loopback addresses, not
        # a dn42 VLAN -- that is dn42i-dev0. The loopback is the router's
        # identity and nothing else would advertise it.
        #
        # The site LANs are deliberately absent. The only circuit today is
        # the lab link to the dev container, which is inside this site, so
        # advertising a site prefix over it would pull local traffic
        # through a gretap at MTU 1382 to reach somewhere one hop away.
        # They go in with the first circuit that leaves the building, which
        # is also the precondition for turning dn42's ibgpInternal off:
        # that switch means "the IGP carries our topology now", and the IGP
        # carries only what this list names.
        passiveInterfaces = [
          "dn42"
          "lab0"
        ];
      };
    };

    # The underlay address for the GRETAP, and a dummy holding the only
    # prefix this router advertises into the IGP.
    systemd.network = {
      netdevs."45-lab0".netdevConfig = {
        Name = "lab0";
        Kind = "dummy";
      };

      networks = {
        "45-lab0" = {
          matchConfig.Name = "lab0";
          address = [ "${ours}1/64" ];
        };

        "40-dev0".address = [ "${link}1/127" ];
      };
    };
  };
}
