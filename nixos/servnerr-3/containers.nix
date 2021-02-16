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

  # Workaround for NixOS containers not stopping at reboot, see:
  # https://github.com/NixOS/nixpkgs/issues/109695#issuecomment-774662261
  systemd.services."shutdown-containers" = {
    description = "Workaround for nixos-containers shutdown";
    enable = true;

    unitConfig = {
      DefaultDependencies = false;
      RequiresMountFor = "/";
    };

    before = [ "shutdown.target" "reboot.target" "halt.target" "final.target" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeScript "containers-shutdown" ''
        #! ${pkgs.runtimeShell} -e
        ${pkgs.nixos-container}/bin/nixos-container list | while read container; do
          ${pkgs.nixos-container}/bin/nixos-container stop $container
        done
      '';
    };
  };
}
