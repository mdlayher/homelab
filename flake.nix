{
  description = "mdlayher's homelab NixOS configurations";

  inputs = {
    # Stable NixOS release used as the base for all machines.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

    # Unstable channel, exposed as pkgs.unstable for packages which should
    # update faster than the stable release.
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable-small";

    # Coding agents and their tooling, packaged within a day of each release
    # for those nixpkgs lags behind; built against the flake's own nixpkgs pin
    # and exposed as pkgs.llm-agents, see nixos/modules/unstable.nix.
    llm-agents.url = "github:numtide/llm-agents.nix";

    # Secrets management via sops and age.
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # MicroVMs for development environments which need their own kernel;
    # see nixos/servnerr-4/dev.nix.
    microvm = {
      url = "github:microvm-nix/microvm.nix";
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
            ./nixos/modules/alloy.nix
            ./nixos/modules/common.nix
            ./nixos/modules/unstable.nix
            ./nixos/modules/inventory.nix
            ./nixos/modules/nix-cache.nix
            ./nixos/modules/rtr-cache.nix
            ./nixos/modules/system-metrics.nix
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
        edge-iad = mkSystem "edge-iad";
        edge-pdx = mkSystem "edge-pdx";
        routnerr-3 = mkSystem "routnerr-3";
        servnerr-4 = mkSystem "servnerr-4";
      };

      # The KVM's configuration, built here and applied by pikvm/deploy; the
      # device runs PiKVM OS rather than NixOS.
      packages = forAllSystems (system: {
        pikvm = import ./pikvm {
          inherit inventory;
          inherit (nixpkgs) lib;
          pkgs = nixpkgs.legacyPackages.${system};
          # consrv 1.3.0 requires go >= 1.27, newer than the stable
          # release's default Go toolchain.
          go = nixpkgs-unstable.legacyPackages.${system}.go_1_27;
          sshKeys = import ./nixos/ssh-keys.nix;
        };
      });

      # nix fmt: Nix files, and HuJSON in the layout Tailscale stores a
      # tailnet policy in, so a tofu plan for it shows only real changes.
      formatter = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        pkgs.nixfmt-tree.override {
          runtimeInputs = [ pkgs.hujsonfmt ];
          settings.formatter.hujsonfmt = {
            command = "hujsonfmt";
            options = [ "-w" ];
            includes = [ "*.hujson" ];
          };
        }
      );

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
              opentofu
              sops
              ssh-to-age
            ];
          };
        }
      );
    };
}
