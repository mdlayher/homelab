{ pkgs, lib, ... }:

let unstable = import <unstable> { };

in {
  containers = {
    # Plex server running containerized and on unstable for faster updates.
    plex = {
      autoStart = true;
      bindMounts = {
        # Mount the ZFS pool as read-only.
        "/primary/media" = {
          hostPath = "/primary/media";
          isReadOnly = true;
        };
      };
      config = { config, pkgs, ... }:
        let unstable = import <unstable> { config.allowUnfree = true; };
        in {
          services.plex = {
            enable = true;
            package = unstable.plex;
          };
        };
    };

    # UniFi controller running containerized and on unstable for faster updates.
    unifi = {
      autoStart = true;
      config = { config, pkgs, ... }:
        let unstable = import <unstable> { config.allowUnfree = true; };
        in {
          services.unifi = {
            enable = true;
            unifiPackage = unstable.unifi;
          };
        };
    };
  };

  docker-containers = {
    # promlens running on TCP/9091 adjacent to Prometheus.
    promlens = {
      image = "promlabs/promlens";
      ports = [ "9091:8080" ];
      volumes = [ "/var/lib/promlens:/var/lib/promlens" ];
    };
  };
}
