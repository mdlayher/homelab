{ pkgs, ... }:

{
  # These services are proprietary and run containerized for confinement from
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
        #"/primary/media" = {
        #  hostPath = "/primary/media";
        #  isReadOnly = true;
        #};
      };
      config = { ... }:
        let
          unstable =
            import <nixos-unstable-small> { config.allowUnfree = true; };
        in {
          system.stateVersion = "21.11";
          services.plex = {
            enable = true;
            package = unstable.plex;
          };
        };
    };

    unifi = {
      autoStart = true;
      config = { ... }:
        let
          unstable =
            import <nixos-unstable-small> { config.allowUnfree = true; };
        in {
          system.stateVersion = "21.11";
          services.unifi = {
            enable = true;
            jrePackage = unstable.jdk11;
            unifiPackage = unstable.unifi;
          };
        };
    };
  };

  virtualisation.oci-containers = {
    backend = "podman";
    containers = {
      home-assistant = {
        image = "ghcr.io/home-assistant/home-assistant:stable";
        extraOptions = [ "--network=host" ];
        ports = [ "8123:8123" ];
        volumes =
          [ "/etc/localtime:/etc/localtime:ro" "/var/lib/hass:/config" ];
      };
    };
  };
}
