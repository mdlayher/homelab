# mdlayher.net — pointed at the house, same as servnerr.com.
#
# The zone previously held only a parking page and an unused mail-forwarding
# setup; none of it is carried over.
#
# As for servnerr.com, the apex A record is owned by the router
# (nixos/routnerr-3/cloudflare-ddns.nix) rather than declared here.

resource "cloudflare_dns_record" "mdlayher_net_caa" {
  zone_id = local.zones["mdlayher.net"]
  name    = "mdlayher.net"
  type    = "CAA"
  ttl     = 1
  data = {
    flags = 0
    tag   = "issue"
    value = "letsencrypt.org"
  }
}

# The stable name handed to dn42 peers (see nixos/routnerr-3/dn42.nix). Peers
# put this in their WireGuard endpoint, so it exists to be repointed here
# rather than by asking every peer to edit their config.
#
# <site>.dn42.<zone> is what dn42 networks overwhelmingly use, with the site
# an IATA code; a survey of the 211 peering endpoints in jlu5/ansible-dn42
# found a dn42 label in 95 of them and "peer" in 6. Naming the site rather
# than taking the bare dn42.<zone> leaves room for a second node without
# renaming this one, and azo is the metro, which is the granularity a peer
# picking a nearby node actually wants.
#
# A CNAME to the apex rather than an address of its own: the WAN addresses are
# the router's to publish, and the apex already carries A and AAAA for the
# WANs currently egressing. So this follows a failover on both families
# instead of pinning peers to a WAN that may be down, and no address is
# declared twice.
resource "cloudflare_dns_record" "mdlayher_net_dn42_azo" {
  zone_id = local.zones["mdlayher.net"]
  name    = "azo.dn42.mdlayher.net"
  type    = "CNAME"
  content = "mdlayher.net"
  ttl     = 1
  proxied = false
}
