# corerad.net — the CoreRAD project site, served by Netlify.
#
# TODO: move the site to Cloudflare Pages and drop Netlify, as for
# mdlayher.com.
resource "cloudflare_dns_record" "corerad_net_apex" {
  zone_id = local.zones["corerad.net"]
  name    = "corerad.net"
  type    = "CNAME"
  content = "corerad.netlify.app"
  ttl     = 1
  proxied = false
}

resource "cloudflare_dns_record" "corerad_net_www" {
  zone_id = local.zones["corerad.net"]
  name    = "www.corerad.net"
  type    = "CNAME"
  content = "corerad.netlify.app"
  ttl     = 1
  proxied = false
}

# Coexists with the flattened apex CNAME: that CNAME is never returned as one,
# so the CNAME-plus-other-data restriction does not apply. The escaped quotes
# are required — the API stores and returns the character-string with them.
resource "cloudflare_dns_record" "corerad_net_google_site_verification" {
  zone_id = local.zones["corerad.net"]
  name    = "corerad.net"
  type    = "TXT"
  content = "\"google-site-verification=rGXguIEftdBkBqAzbLs5GZd3vbH4REHi3lcxv-mMR80\""
  ttl     = 1
}
