# Exposes the nixpkgs-unstable flake input as pkgs.unstable, so any module can
# pull individual packages from unstable via pkgs.unstable.<name>.
{ inputs, lib, ... }:

{
  nixpkgs.overlays = [
    (final: prev: {
      unstable = import inputs.nixpkgs-unstable {
        inherit (prev.stdenv.hostPlatform) system;
        config = {
          # Only allow certain unfree packages from unstable.
          allowUnfreePredicate =
            pkg:
            builtins.elem (lib.getName pkg) [
              "claude-code"
              "plexmediaserver"
            ];
        };
      };
    })
  ];
}
