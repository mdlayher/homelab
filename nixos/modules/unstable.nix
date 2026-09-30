# Exposes the nixpkgs-unstable flake input as pkgs.unstable, so any module can
# pull individual packages from unstable via pkgs.unstable.<name>. The
# llm-agents flake's packages sit under pkgs.llm-agents.<name> for the coding
# agents whose releases nixpkgs lags behind, built against the flake's own
# nixpkgs pin as its CI builds them.
{ inputs, ... }:

{
  nixpkgs.overlays = [
    (final: prev: {
      unstable = import inputs.nixpkgs-unstable {
        inherit (prev.stdenv.hostPlatform) system;
      };
      llm-agents = inputs.llm-agents.packages.${prev.stdenv.hostPlatform.system};
    })
  ];
}
