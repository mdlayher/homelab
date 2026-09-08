# Exposes the nixpkgs-unstable flake input as pkgs.unstable, so any module can
# pull individual packages from unstable via pkgs.unstable.<name>. The
# llm-agents flake's packages, built against that same unstable set, sit
# under pkgs.unstable.llm-agents.<name> for the coding agents whose releases
# nixpkgs lags behind.
{ inputs, lib, ... }:

{
  nixpkgs.overlays = [
    (final: prev: {
      unstable = import inputs.nixpkgs-unstable {
        inherit (prev.stdenv.hostPlatform) system;
        overlays = [ inputs.llm-agents.overlays.shared-nixpkgs ];
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
