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
              DocNastyDub = "d849719b-2438-4ecc-8557-7decc63ad5cb";
              ericthegreat12 = "6853f664-f600-42c5-9d82-934d0ab6df9c";
              HashtagVEGAS = "2dfdd3a5-876b-4042-b2bf-5a49621e998f";
              Ickalanda = "95a91b05-d9df-4660-b902-505d5bd67317";
              jacace = "c25f3433-06b2-4117-88b0-13aee986f7ee";
              jimyMIX = "4419ac6d-0fd9-46ed-a69d-95328460a9cd";
              LayMik64 = "68739061-5f17-4c45-bc77-cca4329b4d2d";
              nerrster = "38f8c307-dde4-4774-a969-f4cc69dec50e";
              rothberry = "5d758298-b38b-4e30-8e02-161373b26c01";
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
