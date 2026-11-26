# The server's dead man's switch: Alertmanager pings this check while
# PrometheusWatchdog fires (nixos/servnerr-4/prometheus.nix), and the
# channels below are notified when the pings stop. Imported, not created:
# its ping URL is the secret alertmanager/deadman_url.
resource "healthchecksio_check" "deadman" {
  name = "Alertmanager watchdog"

  # Alertmanager's two minute ping interval and a server reboot both fit
  # inside period plus grace.
  timeout = 5 * 60
  grace   = 10 * 60

  # Every update sends this list; leaving it empty detaches all channels.
  channels = [for c in data.healthchecksio_channel.notify : c.id]
}

# Channels to notify, by API integration kind; each matches the account's
# first channel of that kind.
data "healthchecksio_channel" "notify" {
  for_each = toset(["discord", "email"])

  kind = each.key
}
