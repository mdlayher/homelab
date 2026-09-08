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

# Single-family variants of azo.dn42, for a peer that wants the WireGuard
# underlay pinned to one family rather than letting its resolver pick from
# the apex's A and AAAA. Each is a CNAME to the corresponding current-egress
# name (see the router's cloudflare-ddns.nix), so it follows a WAN failover
# within its family: ipv4 tracks whichever WAN egresses v4, ipv6 whichever
# egresses v6. Return symmetry holds because a family's reply leaves on that
# family's route regardless of which address the peer targeted.
resource "cloudflare_dns_record" "mdlayher_net_dn42_azo_ipv4" {
  zone_id = local.zones["mdlayher.net"]
  name    = "ipv4.azo.dn42.mdlayher.net"
  type    = "CNAME"
  content = "ipv4.mdlayher.net"
  ttl     = 1
  proxied = false
}

resource "cloudflare_dns_record" "mdlayher_net_dn42_azo_ipv6" {
  zone_id = local.zones["mdlayher.net"]
  name    = "ipv6.azo.dn42.mdlayher.net"
  type    = "CNAME"
  content = "ipv6.mdlayher.net"
  ttl     = 1
  proxied = false
}

# HTTPS records (RFC 9460) for the names the peering page answers on, so a
# resolver that asks for them learns HTTP/3 is available before the first
# connection, instead of after it via the Alt-Svc header the page also
# sends (see nixos/routnerr-3/azo-page.nix). The azo names are CNAMEs to
# these three, and a CNAME cannot carry records of its own, so the records
# live at the targets and reach azo through the alias: the apex for
# azo.dn42, and the per-family names for its ipv4 and ipv6 variants. A "."
# target means this same name's addresses, which stay the router's to
# publish. Clearnet only, like the names themselves; dn42 clients use the
# router's addresses by number.
resource "cloudflare_dns_record" "mdlayher_net_https" {
  for_each = toset([
    "mdlayher.net",
    "ipv4.mdlayher.net",
    "ipv6.mdlayher.net",
  ])

  zone_id = local.zones["mdlayher.net"]
  name    = each.key
  type    = "HTTPS"
  ttl     = 1
  data = {
    priority = 1
    target   = "."
    value    = "alpn=\"h3,h2\""
  }
}
