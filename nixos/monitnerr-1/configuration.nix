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

  # The Pi's hardware watchdog (bcm2835_wdt) tops out around 15 seconds, so
  # the 60 second default from common.nix does not fit.
  systemd.settings.Manager.RuntimeWatchdogSec = lib.mkForce "10s";

  # The fish module generates a completion file from the man pages of every
  # package in the system profile, one uncached derivation per package that
  # the Pi rebuilds itself on every nixpkgs bump: ~150 derivations, pegging
  # its CPU for over ten minutes per deploy. Skip them here; completions that
  # packages ship in their own vendor directories (including the dotfiles from
  # common.nix) are unaffected.
  programs.fish.generateCompletions = false;

  services = {
    # Enable the OpenSSH daemon.
    openssh.enable = true;

    # SD card storage: no SMART to monitor.
    smartd.enable = lib.mkForce false;
    prometheus.exporters.smartctl.enable = lib.mkForce false;
  };
}
