{ pkgs, ... }:

{
  # These services are proprietary and run containerized for confinement from
  # the rest of the system and on unstable for faster update cycles.
  containers = {
    plex = {
      autoStart = true;
      bindMounts = {
        # Mount the ZFS pool as read-only.
        "/primary/media" = {
          hostPath = "/primary/media";
          isReadOnly = true;
        };
      };
      config = { ... }:
        let
          unstable =
            import <nixos-unstable-small> { config.allowUnfree = true; };
        in {
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
          services.unifi = {
            enable = true;
            unifiPackage = unstable.unifi;
          };
        };
    };
  };

  virtualisation.oci-containers = {
    backend = "podman";
    containers = {
      # promlens running on TCP/9091 adjacent to Prometheus.
      promlens = {
        image = "promlabs/promlens";
        ports = [ "9091:8080" ];
        volumes = [ "/var/lib/promlens:/var/lib/promlens" ];
      };
    };
  };
}
