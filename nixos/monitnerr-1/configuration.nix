{ lib, ... }:

{
  imports = [
    # Hardware and networking. The shared base system lives in nixos/modules/
    # and is imported by flake.nix.
    ./hardware-configuration.nix
    ./networking.nix

    # SSH to serial console server.
    ./consrv.nix
  ];

  system.stateVersion = "26.05";

  # Transitional: this machine uses the new admin username.
  homelab.user = "mdlayher";

  # The Pi's hardware watchdog (bcm2835_wdt) tops out around 15 seconds, so
  # the 60 second default from common.nix does not fit.
  systemd.settings.Manager.RuntimeWatchdogSec = lib.mkForce "10s";

  services = {
    # Enable the OpenSSH daemon.
    openssh.enable = true;

    # SD card storage: no SMART to monitor.
    smartd.enable = lib.mkForce false;
    prometheus.exporters.smartctl.enable = lib.mkForce false;
  };
}
