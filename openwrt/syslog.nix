# The server's UDP port for the OpenWrt machines' RFC 3164 syslog, read by
# the server's firewall (nixos/servnerr-4/networking.nix) and its Alloy
# (nixos/servnerr-4/loki.nix), and set on each machine as its logd's
# log_port (./default.nix).
{
  port = 5516;
}
