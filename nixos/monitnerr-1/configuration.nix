{ lib, modulesPath, ... }:

{
  imports = [
    # Hardware and networking. The shared base system lives in nixos/modules/
    # and is imported by flake.nix.
    ./hardware-configuration.nix
    ./networking.nix

    # SSH to serial console server.
    ./consrv.nix

    # No documentation, generated completions, or default packages, which
    # the Pi otherwise builds itself on every nixpkgs bump: fish's completion
    # files alone, one per package from its man pages, pegged its CPU for
    # over ten minutes per deploy. Completions packages ship themselves
    # (including the dotfiles from common.nix) are unaffected.
    (modulesPath + "/profiles/minimal.nix")
  ];

  # This machine is at the home site; see nixos/inventory/.
  homelab.site = "azo";

  system.stateVersion = "26.05";

  # The Pi's hardware watchdog (bcm2835_wdt) tops out around 15 seconds, so
  # the 60 second default from common.nix does not fit.
  systemd.settings.Manager.RuntimeWatchdogSec = lib.mkForce "10s";

  # The server builds this machine's system under emulation and serves it,
  # so the Pi builds only what the server has not.
  homelab.nixCache.client = true;

  services = {
    # Enable the OpenSSH daemon.
    openssh.enable = true;

    # The minimal profile turns logrotate off; it rotates btmp and wtmp.
    logrotate.enable = true;

    # SD card storage: no SMART to monitor.
    smartd.enable = lib.mkForce false;
    prometheus.exporters.smartctl.enable = lib.mkForce false;
  };
}
