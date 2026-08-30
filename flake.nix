{
  description = "mdlayher's homelab NixOS configurations";

  inputs = {
    # Stable NixOS release used as the base for all machines.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

    # Unstable channel, exposed as pkgs.unstable for packages which should
    # update faster than the stable release.
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable-small";

    # Secrets management via sops and age.
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      nixpkgs-unstable,
      sops-nix,
      ...
    }@inputs:
    let
      # Builds a NixOS system for the machine defined in nixos/<name>.
      mkSystem =
        name:
        nixpkgs.lib.nixosSystem {
          specialArgs = { inherit inputs; };
          modules = [
            ./nixos/modules/common.nix
            ./nixos/modules/unstable.nix
            sops-nix.nixosModules.sops
            ./nixos/${name}/configuration.nix
            { networking.hostName = name; }
          ];
        };

      forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" ];
    in
    {
      nixosConfigurations = {
        servnerr-4 = mkSystem "servnerr-4";

        # TODO(mdlayher): routnerr-3 is still deployed from channels and
        # nixos/routnerr-3/configuration.nix. Migrate it here once servnerr-4
        # has settled.
      };

      # nix fmt
      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixfmt-tree);

      # nix develop: tools for working with this repository.
      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.mkShell {
            packages = with pkgs; [
              age
              go
              nixfmt
              sops
              ssh-to-age
            ];
          };
        }
      );
    };
}
