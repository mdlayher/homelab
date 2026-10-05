# The LG TVs running Glasshouse, by inventory host name, read by the
# router's firewall (nixos/routnerr-3/nftables.nix) to admit lgtv/deploy,
# by the server's Prometheus (nixos/servnerr-4/prometheus.nix) for its
# scrape job, and by lgtv/deploy for what it applies to.
{
  hosts = [
    "living-room-lgcx"
    "office-lgc4"
  ];

  # Glasshouse's dashboard and API port.
  port = 8080;
}
