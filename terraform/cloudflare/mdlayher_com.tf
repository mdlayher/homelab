# mdlayher.com — the personal site, served by Netlify.
#
# The apex is a CNAME because Cloudflare flattens CNAMEs at the zone apex on
# every plan, so it answers A/AAAA there while tracking the target. Pinning
# Netlify's edge addresses instead would mean chasing them whenever Netlify
# renumbers.
#
# TODO: move the site to Cloudflare Pages and drop Netlify, so hosting and DNS
# live in one place. These two records become Pages records and the
# *.netlify.app dependency goes away.

resource "cloudflare_dns_record" "mdlayher_com_apex" {
  zone_id = local.zones["mdlayher.com"]
  name    = "mdlayher.com"
  type    = "CNAME"
  content = "mdlayher.netlify.app"
  ttl     = 1
  proxied = false
}

resource "cloudflare_dns_record" "mdlayher_com_www" {
  zone_id = local.zones["mdlayher.com"]
  name    = "www.mdlayher.com"
  type    = "CNAME"
  content = "mdlayher.netlify.app"
  ttl     = 1
  proxied = false
}

# Bluesky handle verification: this is what makes @mdlayher.com resolve to the
# account. Load-bearing, and easy to lose in a migration because nothing in the
# zone's visible records hints at it — found only by sweeping underscore names.
# The escaped quotes are required; the API stores the character-string with them.
resource "cloudflare_dns_record" "mdlayher_com_atproto" {
  zone_id = local.zones["mdlayher.com"]
  name    = "_atproto.mdlayher.com"
  type    = "TXT"
  content = "\"did=did:plc:3h65gi3xzj6tkdrsi6dumbwt\""
  ttl     = 1
}
