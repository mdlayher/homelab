# Tailnet DNS, managed whole. Adopt what was made by hand in the console
# before the first apply; the id is ignored:
#
#   sops-gate tofu-import tailscale tailscale_dns_configuration.tailnet dns_configuration
#
# Machines set --accept-dns=false (nixos/modules/tailscale.nix), so this is
# for personal devices.

locals {
  # The router's CoreDNS, at its tailnet address rather than the LAN ones
  # this replaced: reachable wherever the device is, needing no subnet
  # route, and unmoved by the site's renumbering. Its internal zones bind
  # no address and ts0 is trusted in its ruleset, so it answers there.
  router = "100.113.93.12"

  # The zones the router answers for and public DNS does not.
  internal_domains = [
    "azo.mdlayher.net",
    "iad.mdlayher.net",
    "pdx.mdlayher.net",
    "svc.mdlayher.net",
  ]
}

resource "tailscale_dns_configuration" "tailnet" {
  magic_dns = true

  # The nameservers below resolve everything outside the tailnet, ahead of
  # whatever network a device is attached to. Split DNS matches first, so
  # this reaches public names alone.
  override_local_dns = true

  # MagicDNS adds the tailnet domain; internal names are written in full.
  search_paths = []

  # Google Public DNS, both families.
  nameservers {
    address = "8.8.8.8"
  }

  nameservers {
    address = "8.8.4.4"
  }

  nameservers {
    address = "2001:4860:4860::8888"
  }

  nameservers {
    address = "2001:4860:4860::8844"
  }

  # use_with_exit_node because the router offers one: without it, selecting
  # that exit node takes every internal name dark.
  dynamic "split_dns" {
    for_each = local.internal_domains

    content {
      domain = split_dns.value

      nameservers {
        address            = local.router
        use_with_exit_node = true
      }
    }
  }
}
