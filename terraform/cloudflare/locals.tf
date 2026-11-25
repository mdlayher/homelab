locals {
  # From each zone's overview page in the dashboard. Not secrets.
  zones = {
    "mdlayher.com" = "db4f8fadfe5bffe77456ad42c700e52a"
    "corerad.net"  = "4bd7e44515294fdb382d526cd6e35d14"
    "servnerr.com" = "657638d5af57c1e06f860ac5fed17024"
    "mdlayher.net" = "7d358bd5ac55e8d46dcffb6afaf86854"
  }

  # Each edge's public addresses, from `tofu output` in terraform/aws. That
  # module keeps its own state with no link to this one, so these are copied
  # by hand: a replaced instance keeps its EIP but takes a new ENI address.
  # Every record naming an edge reads them here, so a replacement is one edit.
  pdx_endpoint_v4 = "52.38.132.195"
  pdx_endpoint_v6 = "2600:1f13:ce:ca00:bcc3:f69b:5bd8:251b"

  iad_endpoint_v4 = "44.193.36.229"
  iad_endpoint_v6 = "2600:1f18:2900:e00:f29a:1a95:373b:2479"
}
