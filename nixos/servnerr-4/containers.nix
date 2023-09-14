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
          system.stateVersion = "21.11";
          services.plex = {
            enable = true;
            package = unstable.plex;
          };
        };
    };
  };

  virtualisation.oci-containers = {
    backend = "podman";
    containers = {
      home-assistant = {
        image = "ghcr.io/home-assistant/home-assistant:stable";
        extraOptions = [
          # Expose on the host.
          "--network=host"
          # Pass in Home Assistant SkyConnect device.
          "--device=/dev/serial/by-id/usb-Nabu_Casa_SkyConnect_v1.0_4c34810ea196ed11a365c698a7669f5d-if00-port0"
        ];
        ports = [ "8123:8123" ];
        volumes =
          [ "/etc/localtime:/etc/localtime:ro" "/var/lib/hass:/config" ];
      };
    };
  };
}
