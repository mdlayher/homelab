# The server's UDP ports for a Prusa printer's metrics and log streams, set
# on the printer by M334. The router admits both from the printer
# (nixos/routnerr-3/nftables.nix); the server's Alloy listens on the log
# port (nixos/servnerr-4/loki.nix) and its firewall opens that port alone
# (nixos/servnerr-4/networking.nix).
{
  metricsPort = 5518;
  logPort = 5517;
}
