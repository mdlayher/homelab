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
- `deploy`: builds and applies over SSH as root, in one connection. The
  device first names the files it lacks or holds with another checksum
  or mode, and only those are sent, so a deploy moves kilobytes unless a
  binary's version changed.

```sh
# Show how the device differs from this checkout; changes nothing.
pikvm/deploy --check

# Apply.
pikvm/deploy
```

Each deploy logs its provenance in the KVM's journal, which reaches Loki
under `{unit="deploy"}`, and a finished one is announced in the Discord ops
channel; see lib/deploy.sh.

A deploy may restart kvmd (open web sessions drop, and a change to the
override rebuilds the USB gadget, so the server's KVM keyboard, mouse and
serial port disconnect and return), consrv (open console sessions drop)
and tailscaled (a few seconds off the tailnet, after the deploy has
finished).

## Consoles from the KVM

Root on the KVM opens the serial consoles through consrv, so each session
is logged and announced as one from anywhere else is, and consrv logs its
login as identity `pikvm-root`. `/root/.ssh/config` has a host alias per
console, `console-<name>`, which connects to consrv on 127.0.0.1:2222 with
root's own key, `/root/.ssh/consrv_ed25519`:

```sh
ssh console-router
```

The key is generated on the KVM and its private half never leaves it.
Its public half is committed as `nixos/ssh-keys/pikvm-root.pub`, so the
first deploy after a reflash needs a commit in between:

1. `pikvm/deploy` generates the key and prints its public half after
   `uncommitted:`; every later run prints it again until the build
   carries the same key.
2. Commit that line as `nixos/ssh-keys/pikvm-root.pub` and run
   `pikvm/deploy` again. consrv then accepts the key, and the client
   config is installed.

The server reaches the KVM's own login prompt over USB at `/dev/ttyACM0`,
for when the KVM is off the network:
`sudo minicom -o -b 115200 -D /dev/ttyACM0`.

## Not managed here

Generated or set on the device, and never copied off it:

- the root password, and the web UI login and its TOTP secret
  (`kvmd-htpasswd`, `kvmd-totp`)
- tailscaled's state, which holds the node identity, its `tag:kvm` tag and
  the `svc:consrv` serve configuration; `apply.sh` re-creates the serve
  configuration when it is missing
- consrv's SSH host key at `/etc/consrv/host_key`, which `apply.sh`
  generates when it is missing, and root's known hosts file for it,
  `/root/.ssh/known_hosts_consrv`, which `apply.sh` writes from it
- root's consrv key at `/root/.ssh/consrv_ed25519`, which `apply.sh`
  generates when it is missing; see Consoles from the KVM

## Rebuilding after a reflash

1. Flash PiKVM OS, then as root: `rw`, `passwd`, `kvmd-htpasswd set admin`,
   `kvmd-totp init`, and `pikvm-update`.
2. `pacman -S` every package in `packages` in `default.nix`, then
   `systemctl enable --now tailscaled ModemManager NetworkManager`.
   `apply.sh` refuses to run while one is missing.
3. Join the tailnet with `tailscale up --hostname=pikvm`, give the machine
   `tag:kvm` in the admin console, and `ro`.
4. Install the admin's keys by hand so the first deploy can log in, from
   `nixos/ssh-keys.nix` into `/root/.ssh/authorized_keys`.
5. `pikvm/deploy`. The first one generates consrv's host key, so SSH
   clients see a new one for `consrv.<tailnet>.ts.net`. It also generates
   root's consrv key; commit its public half and deploy again, as in
   Consoles from the KVM.

tailscaled writes its state under the read-only root, so any `tailscale up`,
`set` or `serve` must run between `rw` and `ro` or it is lost at the next
reboot.
