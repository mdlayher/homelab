# Tailscale client configuration shared by every machine.
{ pkgs, ... }:

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

    # tailscaled's port mapper probes the default gateway for NAT-PMP, PCP
    # and UPnP every few minutes, hoping to open a public port for direct
    # connections. The router deliberately runs none of those: inbound
    # direct paths come from its static per-device forwards, its peer relay
    # or DERP (see the router's nftables.nix), so every probe is dropped and
    # retried forever, and on the restricted VLANs each one is logged. The
    # knob turns the mapper off before it sends anything; STUN-discovered
    # endpoints and everything else are unaffected.
    environment.TS_DISABLE_PORTMAPPER = "1";
  };

  # With accept-dns off, tailnet names resolve through the router like every
  # other name: its CoreDNS forwards the tailnet domain to its own tailscaled
  # (see the router's coredns.nix). Tailnet names on this machine therefore
  # depend on the router's CoreDNS and tailscaled, not on this machine's own
  # tailscaled; the router is already its resolver for everything else.
}
