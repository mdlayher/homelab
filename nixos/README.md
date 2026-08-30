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

- `<machine>/secrets.yaml`: per-machine secrets (password hashes, tokens)
- `inventory/secrets.yaml`: network inventory values, see below

## Inventory

`inventory/default.nix` declares the network's structure: subnets (VLAN ID,
trust level) and the hosts on them, with each host's IPv6 addressing mode.
Every address, prefix, and MAC lives in `inventory/secrets.yaml`:

```yaml
site:
  ula_prefix: fd9e:1a04:f01d          # the ULA /48
subnets:
  lan0:
    ipv4_prefix: 192.168.10           # router is .1
    ula_prefix: fd9e:1a04:f01d:10     # router is ::1
    gua_prefix: 2600:6c4a:783f:780a   # update if the ISP renumbers
hosts:
  matt-4:
    mac: 14:ac:60:46:8d:91
    ipv4: 192.168.10.13
    iid: 16ac:60ff:fe46:8d91          # joined as "<prefix>:<iid>"
```

Per-host `iid` values are exactly four hex groups. How they are chosen is the
host's `ipv6` mode in `inventory/default.nix`:

- `eui64`: derived from the MAC. Compute it with
  `nix eval --raw --impure --expr '(import ./nixos/inventory/lib.nix { lib = (builtins.getFlake (toString ./.)).inputs.nixpkgs.lib; }).eui64 "44:5b:ed:f7:ce:da"'`.
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
sops nixos/inventory/secrets.yaml
sops nixos/routnerr-3/secrets.yaml

# Check that every configuration evaluates, and format Nix files.
nix flake check
nix fmt

# Bump inputs (also done weekly by .github/workflows/update-flake-lock.yml).
nix flake update

# Deploy, on the machine itself. On the router, prefer `test` before `switch`:
# it activates without a boot entry, so a reboot reverts it.
sudo nixos-rebuild switch --flake /home/matt/src/homelab#servnerr-4
sudo nixos-rebuild test --flake /home/matt/src/homelab#routnerr-3
```

`system.autoUpgrade` rebuilds nightly from `github:mdlayher/homelab`, so
upgrades roll out when a `flake.lock` bump lands on `main`.
