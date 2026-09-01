# Tailscale Services published by the machines. Each service here pairs with
# a homelab.tailscale.services entry in a machine's NixOS configuration, which
# renders the serve configuration on the hosting side; see
# nixos/modules/tailscale-serve.nix. Machines self-approve as hosts via the
# autoApprovers policy in policy.hujson, so defining the service is the only
# tailnet-side step.
#
# Before the first apply, adopt the services that were created by hand in the
# admin console; the plan must then show only new services (loki) as creates:
#
#   tofu import 'tailscale_service.web["alertmanager"]' svc:alertmanager
#   tofu import 'tailscale_service.web["grafana"]' svc:grafana
#   tofu import 'tailscale_service.web["prometheus"]' svc:prometheus
#   tofu import tailscale_service.consrv svc:consrv

locals {
  # Monitoring web UIs on the server: TLS terminated on 443 with a plain HTTP
  # convenience on 80; see nixos/servnerr-4/prometheus.nix.
  web_services = toset([
    "alertmanager",
    "grafana",
    "loki",
    "prometheus",
  ])

  comment = "managed by mdlayher/homelab"
}

resource "tailscale_service" "web" {
  for_each = local.web_services

  name    = "svc:${each.value}"
  comment = local.comment
  ports   = ["tcp:80", "tcp:443"]
  tags    = ["tag:infra"]
}

# Serial console SSH server on the monitor; see nixos/monitnerr-1/consrv.nix.
resource "tailscale_service" "consrv" {
  name    = "svc:consrv"
  comment = local.comment
  ports   = ["tcp:22"]
  tags    = ["tag:infra"]
}
