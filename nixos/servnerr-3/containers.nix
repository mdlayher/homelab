{ pkgs, ... }:

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
              enforce-whitelist = true;
              white-list = true;
            };

            whitelist = {
              blalex93 = "b0d98aa2-8284-4830-b06e-a205ee0f166b";
              DocNastyDub = "d849719b-2438-4ecc-8557-7decc63ad5cb";
              ericthegreat12 = "6853f664-f600-42c5-9d82-934d0ab6df9c";
              HashtagVEGAS = "2dfdd3a5-876b-4042-b2bf-5a49621e998f";
              nerrster = "38f8c307-dde4-4774-a969-f4cc69dec50e";
              rothberry = "5d758298-b38b-4e30-8e02-161373b26c01";
              Son_of_a_Teacher = "42cc4da3-3d2a-4cc3-9b2d-897f93438594";
              TheWrat = "dcc01480-e7d9-4f1d-9eb2-87ebb1e6af74";
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
      home-assistant = {
        image = "homeassistant/home-assistant:stable";
        extraOptions = [ "--network=host" ];
        ports = [ "8123:8123" ];
        volumes =
          [ "/etc/localtime:/etc/localtime:ro" "/var/lib/hass:/config" ];
      };

      # promlens running on TCP/9091 adjacent to Prometheus.
      promlens = {
        image = "promlabs/promlens";
        ports = [ "9091:8080" ];
        volumes = [ "/var/lib/promlens:/var/lib/promlens" ];
      };
    };
  };
}
