{ ... }:

{
  # These services are proprietary and run containerized for confinement from
  # the rest of the system and on unstable for faster update cycles.
  containers = {
    minecraft = {
      autoStart = true;
      bindMounts = {
        # Mount the data directory as read/write.
        "/var/lib/minecraft" = {
          hostPath = "/var/lib/minecraft";
          isReadOnly = false;
        };
      };
      config = { ... }:
        let
          secrets = import ./lib/secrets.nix;
          unstable =
            import <nixos-unstable-small> { config.allowUnfree = true; };
        in {
          services.minecraft-server = {
            enable = true;
            package = unstable.minecraft-server;

            eula = true;
            declarative = true;

            # Use more RAM!
            jvmOpts = "-Xmx16384M -Xms16384M";

            serverProperties = {
              motd = "Matt's Minecraft server";
              enable-rcon = true;
              "rcon.password" = secrets.minecraft.rcon;
              pvp = false;
              view-distance = 15;
            };

            whitelist = {
              jacace = "c25f3433-06b2-4117-88b0-13aee986f7ee";
              nerrster = "38f8c307-dde4-4774-a969-f4cc69dec50e";
            };
          };
        };
    };

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
