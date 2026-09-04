# servnerr.com — points at the house.
#
# The public zone is unrelated to the internal servnerr.com the router's
# CoreDNS serves; they only share a name.
#
# The apex A record is deliberately absent here: it follows the WAN address,
# so the router owns it (nixos/routnerr-3/cloudflare-ddns.nix). Declaring it
# in both places would mean terraform and the updater fighting over it.

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
