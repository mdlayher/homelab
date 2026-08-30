# Tailscale client configuration shared by every machine.
{ pkgs, ... }:

{
  services.tailscale = {
    enable = true;
    package = pkgs.unstable.tailscale;
    interfaceName = "ts0";
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
}
