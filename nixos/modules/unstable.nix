# Exposes the nixpkgs-unstable flake input as pkgs.unstable, so any module can
# pull individual packages from unstable via pkgs.unstable.<name>. The
# llm-agents flake's packages sit under pkgs.llm-agents.<name> for the coding
# agents whose releases nixpkgs lags behind, built against the flake's own
# nixpkgs pin as its CI builds them.
{ config, inputs, ... }:

{
  nixpkgs.overlays = [
    (final: prev: {
      unstable = import inputs.nixpkgs-unstable {
        inherit (prev.stdenv.hostPlatform) system;
        # A machine's unfree allowance, where it has one, covers unstable
        # packages too.
        config = builtins.intersectAttrs { allowUnfreePredicate = null; } config.nixpkgs.config;
      };
      llm-agents = inputs.llm-agents.packages.${prev.stdenv.hostPlatform.system};
    })

    # nginx 1.30.7, which fixes the remote code execution in HTTP/2
    # (CVE-2026-123007) and the bugs disclosed with it. Evaluation fails
    # once the nixpkgs pin carries that release, when this is removed.
    (final: prev: {
      nginxStable =
        assert prev.lib.assertMsg (prev.lib.versionOlder prev.nginxStable.version "1.30.7")
          "nixpkgs carries nginx 1.30.7 or later: remove the nginxStable overlay in modules/unstable.nix";
        prev.nginxStable.overrideAttrs (old: rec {
          version = "1.30.7";
          src = prev.fetchurl {
            url = "https://nginx.org/download/nginx-${version}.tar.gz";
            hash = "sha256-JWW1yDcFDpWPcPsPc8SOK8pFQq00n9NW9G+wxyYQvG4=";
          };
        });
    })
  ];
}
