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
}
