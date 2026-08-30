# nixos

NixOS configurations for my machines, built from the `flake.nix` at the root
of this repository. Individual machines have their own directories:

- `routnerr-3/`: home router (WAN, VLANs, DHCP, DNS, IPv6 RAs, nftables)
- `servnerr-4/`: home server (monitoring, hypervisor, NAS)

Shared configuration lives in `modules/`:

- `modules/common.nix`: base system, users, nix settings, auto-upgrade
- `modules/inventory.nix`: exposes the network inventory as `config.homelab.inventory`
- `modules/tailscale.nix`: Tailscale client
- `modules/unstable.nix`: exposes the `nixpkgs-unstable` input as `pkgs.unstable`

## Secrets

Secrets are encrypted with [sops-nix](https://github.com/Mic92/sops-nix) using
age. Recipients are listed in `.sops.yaml`: each machine's SSH host key (via
`ssh-to-age`) plus the admin key in `~/.config/sops/age/keys.txt`.

- `secrets/common.yaml`: secrets every machine needs (user password hashes)
- `<machine>/secrets.yaml`: secrets specific to one machine (service tokens)
- `inventory/secrets.yaml`: network inventory values, see below

## Inventory

`inventory/default.nix` declares the network's structure: subnets (VLAN ID,
trust level) and the hosts on them, with each host's IPv6 addressing mode.
Every address, prefix, and MAC lives in `inventory/secrets.yaml`:

```yaml
site:
  ula_prefix: fd00:1234:5678          # the ULA /48
subnets:
  lan0:
    ipv4_prefix: 192.0.2             # router is .1
    ula_prefix: fd00:1234:5678:10     # router is ::1
    gua_prefix: 2001:db8:0:a   # update if the ISP renumbers
hosts:
  example:
    mac: 02:00:5e:00:53:01
    ipv4: 192.0.2.13
    iid: 0:5eff:fe00:5301          # joined as "<prefix>:<iid>"
```

Per-host `iid` values are exactly four hex groups. How they are chosen is the
host's `ipv6` mode in `inventory/default.nix`:

- `eui64`: derived from the MAC. Compute it with
  `nix eval --raw --impure --expr '(import ./nixos/inventory/lib.nix { lib = (builtins.getFlake (toString ./.)).inputs.nixpkgs.lib; }).eui64 "02:00:5e:00:53:01"'`.
- `token`: the host configures a fixed IID (networkd `Token=static:::10` →
  `0:0:0:10`).
- `prefixstable`: RFC 7217 stable privacy addresses; record the observed IIDs
  as `iid_ula` and `iid_gua`.
- omitted: no IPv6 address is known; the host gets an A record only.

`modules/inventory.nix` turns this into `config.homelab.inventory`, where every
address is a sops placeholder. Consumers render it at activation time through
`sops.templates`: the router's networkd drop-ins (addresses, DHCP static
leases), the CoreDNS hosts file, and nftables set elements. Nothing from the
inventory ends up in the Nix store.

## Workflow

```sh
# Enter a shell with sops, age, ssh-to-age, go, and nixfmt.
nix develop

# Edit secrets.
sops nixos/secrets/common.yaml
sops nixos/inventory/secrets.yaml
sops nixos/servnerr-4/secrets.yaml

# Check that every configuration evaluates, and format Nix files.
nix flake check
nix fmt

# Bump inputs (also done weekly by .github/workflows/update-flake-lock.yml).
nix flake update

# Deploy from any machine with this checkout: builds locally, then activates
# over SSH (as root on servnerr-4; as matt with a sudo prompt on the router).
# Prefer `test` before `switch` on the router: it activates without a boot
# entry, so a reboot reverts it.
nixos/deploy.sh servnerr-4
nixos/deploy.sh routnerr-3 test
nixos/deploy.sh routnerr-3 switch

# Or on the machine itself.
sudo nixos-rebuild switch --flake /home/matt/src/homelab#servnerr-4
```

## Upgrades

`system.autoUpgrade` on every machine rebuilds nightly from
`github:mdlayher/homelab`, so upgrades roll out when a `flake.lock` bump lands
on `main`. The `update-flake-lock` workflow opens that PR weekly and enables
auto-merge, and the `nix` workflow evaluates and builds every machine on each
PR. For this to work end to end, the repository needs:

- an `UPDATE_FLAKE_LOCK_TOKEN` secret holding a personal access token with
  contents and pull request write access, so that the PR triggers CI
- auto-merge enabled, with a branch protection rule on `main` requiring the
  `nix` workflow's checks

Without those, the PR is still opened and can be merged by hand.
