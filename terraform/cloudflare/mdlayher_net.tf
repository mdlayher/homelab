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
