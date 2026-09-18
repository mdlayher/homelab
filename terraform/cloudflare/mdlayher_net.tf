# mdlayher.net — the public zone for this network: the house, the edge, and
# the names one site dials to reach another.
#
# The zone previously held only a parking page and an unused mail-forwarding
# setup; none of it is carried over.
#
# Every name whose value is an address the router observes is owned by the
# router (nixos/routnerr-3/cloudflare-ddns.nix) rather than declared here,
# the apex included. What is declared here is what someone chose.

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

# The pdx site, built by terraform/aws; its addresses are in locals.tf.
resource "cloudflare_dns_record" "mdlayher_net_dn42_pdx_ipv4" {
  zone_id = local.zones["mdlayher.net"]
  name    = "pdx.dn42.mdlayher.net"
  type    = "A"
  content = local.pdx_endpoint_v4
  ttl     = 1
  proxied = false
}

resource "cloudflare_dns_record" "mdlayher_net_dn42_pdx_ipv6" {
  zone_id = local.zones["mdlayher.net"]
  name    = "pdx.dn42.mdlayher.net"
  type    = "AAAA"
  content = local.pdx_endpoint_v6
  ttl     = 1
  proxied = false
}

# Interconnect carrier endpoints, under a label of their own. A name of the
# form <family>.<site>.icl is how one site dials another's WireGuard carrier,
# the same shape at every end. They have nothing to do with dn42 beyond
# sharing a host, and they sit here rather than under <site>.mdlayher.net
# because the router answers authoritatively for that zone and would return
# NXDOMAIN -- and the router is the machine that has to resolve these to
# bring a circuit up.
#
# Split by family because the carrier cannot choose one: each carrier is
# pinned to one of azo's WANs by a firewall mark, and Metronet has no IPv6,
# so the carrier marked for it has to name an address it can actually reach.
# See nixos/routnerr-3/interconnect.nix.
#
# A site whose addresses are static names them directly; a site whose
# addresses move names an alias of what the router publishes for one uplink
# (nixos/routnerr-3/cloudflare-ddns.nix). One uplink, never a current-egress
# name: circuits to azo have to land on different uplinks to be independent,
# and a current-egress name follows a failover onto whichever uplink survives.
# So the family label is what selects an uplink at azo, which holds while
# Metronet carries no IPv6; when that changes, point one of these at the
# uplink name that already exists.
resource "cloudflare_dns_record" "mdlayher_net_icl_azo_ipv4" {
  zone_id = local.zones["mdlayher.net"]
  name    = "ipv4.azo.icl.mdlayher.net"
  type    = "CNAME"
  content = "ipv4.metronet.azo.icl.mdlayher.net"
  ttl     = 1
  proxied = false
}

resource "cloudflare_dns_record" "mdlayher_net_icl_azo_ipv6" {
  zone_id = local.zones["mdlayher.net"]
  name    = "ipv6.azo.icl.mdlayher.net"
  type    = "CNAME"
  content = "ipv6.spectrum.azo.icl.mdlayher.net"
  ttl     = 1
  proxied = false
}

# The edge has one uplink, so its addresses are the records. From locals.tf.
resource "cloudflare_dns_record" "mdlayher_net_icl_pdx_ipv4" {
  zone_id = local.zones["mdlayher.net"]
  name    = "ipv4.pdx.icl.mdlayher.net"
  type    = "A"
  content = local.pdx_endpoint_v4
  ttl     = 1
  proxied = false
}

resource "cloudflare_dns_record" "mdlayher_net_icl_pdx_ipv6" {
  zone_id = local.zones["mdlayher.net"]
  name    = "ipv6.pdx.icl.mdlayher.net"
  type    = "AAAA"
  content = local.pdx_endpoint_v6
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
