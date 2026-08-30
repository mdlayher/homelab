# nixos

NixOS configurations for my machines. I cannot say whether or not these configs
are truly idiomatic, but they work well enough for my needs. Individual
machines have their own directories, such as `routnerr-3/` or `servnerr-4/`.

## Flake-managed machines

`servnerr-4` is built from the `flake.nix` at the root of this repository.
Shared configuration for flake-managed machines lives in `modules/`:

- `modules/common.nix`: base system, users, nix settings, auto-upgrade
- `modules/unstable.nix`: exposes the `nixpkgs-unstable` input as `pkgs.unstable`

Secrets are encrypted with [sops-nix](https://github.com/Mic92/sops-nix) and
committed as `<machine>/secrets.yaml`. Recipients are listed in `.sops.yaml`:
each machine's SSH host key (via `ssh-to-age`) plus the admin key in
`~/.config/sops/age/keys.txt`.

```sh
# Enter a shell with sops, age, ssh-to-age, go, and nixfmt.
nix develop

# Edit a machine's secrets.
sops nixos/servnerr-4/secrets.yaml

# Check that every configuration evaluates, and format Nix files.
nix flake check
nix fmt

# Bump inputs (also done weekly by .github/workflows/update-flake-lock.yml).
nix flake update

# Deploy, on the machine itself.
sudo nixos-rebuild switch --flake /home/matt/src/homelab#servnerr-4
```

`system.autoUpgrade` rebuilds nightly from `github:mdlayher/homelab`, so
upgrades roll out when a `flake.lock` bump lands on `main`.

## Channel-managed machines

`routnerr-3` is still deployed from channels via `routnerr-3/configuration.nix`
and the shared `lib/system.nix`. `lib/` is intentionally left alone until the
router is migrated to the flake. `lib/vars.nix` and `lib/vars.json` (generated
by `lib/vargen`) are shared by both styles.
