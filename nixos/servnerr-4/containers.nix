{ pkgs, ... }:

{
  # These services are proprietary and run in systemd containers for confinement from
  # the rest of the system and on unstable for faster update cycles.
  containers = {
    plex = {
      autoStart = true;
      bindMounts = {
        # Mount Plex data directory as read-write.
        "/var/lib/plex" = {
          hostPath = "/var/lib/plex";
          isReadOnly = false;
        };
        # Mount the ZFS pool as read-only.
        "/primary/media" = {
          hostPath = "/primary/media";
          isReadOnly = true;
        };
      };
      config =
        { ... }:
        let
          unstable = import <nixos-unstable-small> { config.allowUnfree = true; };
        in
        {
          system.stateVersion = "21.11";
          services.plex = {
            enable = true;
            package = unstable.plex;
          };
        };
    };
  };

  # libvirtd hypervisor.
  virtualisation.libvirtd = {
    enable = true;
    onBoot = "start";
  };
}
