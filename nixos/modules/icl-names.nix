# The names a site's interconnect carriers are dialled at and answer for,
# <family>.<site>.icl.<zone>, shared by the interconnect module, which
# dials them, and the page module, which serves them, so the two cannot
# drift apart. The zone is the public one: a literal rather than the
# inventory's, which names the zone a router serves internally, and the two
# share a string and nothing else. The label sits under its own apex rather
# than the site's, because a router answers for its site zone itself and
# would NXDOMAIN the name it has to resolve to dial.
let
  zone = "mdlayher.net";
in
{
  inherit zone;
  dial = family: site: "${family}.${site}.icl.${zone}";
}
