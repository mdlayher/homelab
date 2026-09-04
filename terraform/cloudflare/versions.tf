# Public authoritative DNS. The registrar is elsewhere and stays there; only
# the NS delegation points at Cloudflare, and that change is made by hand.
#
# Applied as `sops-gate tofu-apply cloudflare` (see nixos/servnerr-4/dev.nix).
# The credential is in secrets/cloudflare.yaml under CLOUDFLARE_API_TOKEN,
# scoped to DNS:Edit on these zones and nothing else.
#
# Internal servnerr.com and .dev names are the router's CoreDNS
# (nixos/routnerr-3/coredns.nix) and share nothing with the zones here.
#
# Throughout: records are DNS-only, since Cloudflare is authoritative DNS here
# and nothing else, and ttl = 1 is its "automatic", served as 300s unproxied.
#
# Zones arrive one at a time. tofu reads every *.tf in this directory, so a
# zone whose Cloudflare zone does not exist yet would make the plan propose
# creating its records against a REPLACE_ME id — never empty, and failing on
# apply. Those zones are parked as <zone>.tf.pending, which tofu ignores.
# Rename one back to .tf only once its Cloudflare zone exists and its id is
# filled into locals.tf, then import before applying. Unused keys in the zones
# map are harmless, so the map lists all four from the start.
#
# CAA is deliberately asymmetric. servnerr.com and mdlayher.net pin
# letsencrypt.org; the Netlify-served zones carry none. Netlify owns
# certificate issuance for those two, so pinning a CA we do not control risks
# silently breaking renewal if Netlify ever changes issuer. Absent CAA is
# permissive, not a gap.
terraform {
  required_version = ">= 1.8.0"

  # State is local to the gate: the path is supplied at init time.
  backend "local" {}

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = ">= 5.0.0"
    }
  }
}

provider "cloudflare" {}
