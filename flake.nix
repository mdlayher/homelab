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
      # Network inventory structure shared by all machines; see nixos/inventory/.
      inventory = import ./nixos/inventory;

      # Builds a NixOS system for the machine defined in nixos/<name>.
      mkSystem =
        name:
        nixpkgs.lib.nixosSystem {
          specialArgs = { inherit inputs inventory; };
          modules = [
            ./nixos/modules/common.nix
            ./nixos/modules/unstable.nix
            ./nixos/modules/inventory.nix
            ./nixos/modules/tailscale.nix
            ./nixos/modules/tailscale-serve.nix
            sops-nix.nixosModules.sops
            ./nixos/${name}/configuration.nix
            { networking.hostName = name; }
          ];
        };

      forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" ];
    in
    {
      nixosConfigurations = {
        monitnerr-1 = mkSystem "monitnerr-1";
        routnerr-3 = mkSystem "routnerr-3";
        servnerr-4 = mkSystem "servnerr-4";
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
