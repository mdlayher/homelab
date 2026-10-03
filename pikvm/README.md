# pikvm

The KVM: a PiKVM V4 Plus on the management LAN, attached to the server's
HDMI and USB, with the router's and server's serial consoles on USB adapters
and an LTE modem. It runs PiKVM OS (Arch Linux ARM with a read-only root),
not NixOS, so this directory builds the files the repository manages on it
and `deploy` copies them into place.

- `default.nix`: the managed files, rendered from the same data the machines
  read: the admin's SSH keys (`nixos/ssh-keys.nix`), the development
  container's tailnet addresses and the KVM's Tailscale port
  (`nixos/inventory/`). Built as `.#pikvm`. Each text file opens with a
  comment saying it is managed by `pikvm/deploy`.
- `apply.sh`: runs on the device; installs what differs and restarts or
  reloads what the changed files belong to.
- `deploy`: builds and applies over SSH as root.

```sh
# Show how the device differs from this checkout; changes nothing.
pikvm/deploy --check

# Apply.
pikvm/deploy
```

A deploy may restart kvmd (open web sessions drop), consrv (open
console sessions drop) and tailscaled (a few seconds off the tailnet, after
the deploy has finished).

## Not managed here

Generated or set on the device, and never copied off it:

- the root password, and the web UI login and its TOTP secret
  (`kvmd-htpasswd`, `kvmd-totp`)
- tailscaled's state, which holds the node identity, its `tag:kvm` tag and
  the `svc:consrv` serve configuration; `apply.sh` re-creates the serve
  configuration when it is missing
- consrv's SSH host key at `/etc/consrv/host_key`, which `apply.sh`
  generates when it is missing

## Rebuilding after a reflash

1. Flash PiKVM OS, then as root: `rw`, `passwd`, `kvmd-htpasswd set admin`,
   `kvmd-totp init`, and `pikvm-update`.
2. Install the packages: `pacman -S tailscale-pikvm modemmanager
   networkmanager`, then `systemctl enable --now tailscaled ModemManager
   NetworkManager`.
3. Join the tailnet with `tailscale up --hostname=pikvm`, give the machine
   `tag:kvm` in the admin console, and `ro`.
4. Install the admin's keys by hand so the first deploy can log in, from
   `nixos/ssh-keys.nix` into `/root/.ssh/authorized_keys`.
5. `pikvm/deploy`. The first one generates consrv's host key, so SSH
   clients see a new one for `consrv.<tailnet>.ts.net`.

tailscaled writes its state under the read-only root, so any `tailscale up`,
`set` or `serve` must run between `rw` and `ro` or it is lost at the next
reboot.
