# Tailscale client configuration shared by every machine.
{
  inventory,
  lib,
  pkgs,
  ...
}:

{
  services.tailscale = {
    enable = true;
    package = pkgs.unstable.tailscale;
    interfaceName = "ts0";
    # Open this machine's tailscale UDP port so LAN peers connect directly.
    # A no-op on the router, which runs its own nftables ruleset.
    openFirewall = true;
    # The router's DNS is authoritative on the LAN. Left to its own devices,
    # tailscaled injects the tailnet domain as the FIRST search domain and
    # claims the default DNS route, so single-label names resolve to tailnet
    # addresses and "LAN" traffic silently rides ts0 — which the tailnet policy
    # does not permit between machines.
    extraSetFlags = [ "--accept-dns=false" ];
  };

  # Tailscale readiness and DNS tweaks.
  systemd.network.wait-online.ignoredInterfaces = [ "ts0" ];

  systemd.services.tailscaled = {
    after = [
      "network-online.target"
      "systemd-resolved.service"
    ];
    wants = [ "network-online.target" ];
  };

  # With accept-dns off, tailnet names would not resolve at all: the tailnet
  # domain is not in public DNS and CoreDNS has no zone for it. Route exactly
  # that domain (and nothing else: ~ means route-only, no search) to this
  # machine's own tailscaled resolver, which answers for every peer and
  # service in its netmap — e.g. the server probing its own
  # https://<service>.<tailnet> endpoints.
  #
  # The config rides a dummy interface because tailscaled owns ts0's resolved
  # state and reasserts it empty (accept-dns is off) seconds after every
  # start, wiping anything placed there — ordering cannot win that race.
  # Which link carries the config is irrelevant to packet flow: routes to the
  # virtual resolver address are tailscaled's either way.
  systemd.network = {
    netdevs."20-tsdns0" = {
      netdevConfig = {
        Name = "tsdns0";
        Kind = "dummy";
      };
    };
    networks."20-tsdns0" = {
      matchConfig.Name = "tsdns0";
      networkConfig = {
        # resolved only activates a DNS scope on links with a global address
        # (link-local-only links sit in "degraded" and are skipped). The
        # documentation address never leaves the host: the dummy is NOARP
        # and nothing routes to it.
        Address = "192.0.2.53/32";
        DNS = "100.100.100.100";
        Domains = "~${inventory.tailnetDomain}";
        LLMNR = false;
      };
      linkConfig.RequiredForOnline = false;
    };
  };
}
