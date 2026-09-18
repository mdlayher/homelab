# servnerr.com — the Home Assistant name and the CAA that lets it be issued.
#
# The zone does not point at the house. The router publishes nothing into it,
# nginx serves no vhost for it and holds no certificate covering it, so an
# address record here would resolve to a machine that refuses the connection.
# The network's public names live in mdlayher.net.

resource "cloudflare_dns_record" "servnerr_com_caa" {
  zone_id = local.zones["servnerr.com"]
  name    = "servnerr.com"
  type    = "CAA"
  ttl     = 1
  data = {
    flags = 0
    tag   = "issue"
    value = "letsencrypt.org"
  }
}

resource "cloudflare_dns_record" "servnerr_com_hass" {
  zone_id = local.zones["servnerr.com"]
  name    = "hass.servnerr.com"
  type    = "CNAME"
  content = "8ylqe9df8knqtet2nxyhukgosjvxarb9.ui.nabu.casa"
  ttl     = 1
  proxied = false
}

# Delegates ACME DNS-01 validation for the name above into Nabu Casa's zone,
# so they can renew its certificate. Load-bearing: drop this and the hass
# certificate stops renewing, silently, at its next expiry.
resource "cloudflare_dns_record" "servnerr_com_hass_acme_challenge" {
  zone_id = local.zones["servnerr.com"]
  name    = "_acme-challenge.hass.servnerr.com"
  type    = "CNAME"
  content = "_acme-challenge.8ylqe9df8knqtet2nxyhukgosjvxarb9.ui.nabu.casa"
  ttl     = 1
  proxied = false
}
