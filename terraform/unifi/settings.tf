resource "unifi_setting" "site" {
  # The regulatory domain, as an ISO 3166-1 numeric code: the United States.
  country = {
    code = 840
  }

  # Device firmware upgrades itself at the hour the NixOS machines run
  # their nightly upgrade.
  mgmt = {
    auto_upgrade      = true
    auto_upgrade_hour = 4
  }

  # Time from the anycast NTP address (nixos/inventory/default.nix,
  # anycast4), the server DHCP hands every LAN client.
  ntp = {
    setting_preference = "manual"
    ntp_server_1       = "10.0.0.123"
  }

  # Device logs to the raw syslog listener of the machine holding the loki
  # service (nixos/inventory/default.nix, services), which labels each
  # sender by its inventory address (nixos/servnerr-4/loki.nix). The
  # controller's own log reaches Loki from its journal already.
  syslog = {
    enabled          = true
    ip               = "loki.svc.mdlayher.net"
    port             = 5514
    log_all_contents = true
    this_controller  = false
  }
}
