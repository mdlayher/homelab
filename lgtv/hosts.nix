# The LG TVs running Glasshouse, by inventory host name, read by the
# router's firewall (nixos/routnerr-3/nftables.nix) to admit lgtv/deploy
# and the TVs' syslog, by the server's Prometheus
# (nixos/servnerr-4/prometheus.nix) for its scrape job and its Alloy
# (nixos/servnerr-4/loki.nix) for the syslog listener, and by lgtv/deploy
# for what it applies to.
{
  hosts = [
    "living-room-lgcx"
    "office-lgc4"
  ];

  # Glasshouse's dashboard and API port.
  port = 8080;

  # The server's UDP port for Glasshouse's RFC 5424 syslog forwarding.
  syslogPort = 5515;
}
