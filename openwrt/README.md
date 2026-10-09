# openwrt

The OpenWrt machines: the jump role holders in the inventory, out-of-band
routers on their own LTE uplinks. They run OpenWrt, not NixOS, so this
directory builds the uci settings and files the repository manages on them
and `deploy` applies them.

- `default.nix`: the managed settings and files, rendered from the same data
  the machines read: the admin's SSH keys (`nixos/ssh-keys.nix`), the
  internal zone (`nixos/inventory/`) and the server's syslog port
  (`syslog.nix`). Built as `.#openwrt`, a directory per machine.
- `apply.sh`: runs on the machine; sets what differs, commits it, and
  reloads or restarts what the changes belong to.
- `deploy`: builds and applies over SSH as root.

```sh
# Show how the machine differs from this checkout; changes nothing.
openwrt/deploy --check

# Apply.
openwrt/deploy
```

The deploy logs in over the tailnet to a dropbear instance on its own port
(`sshPort` in `default.nix`), which accepts only the admin's FIDO2 keys, so
a deploy is one touch. Port 22 on the tailnet is Tailscale SSH, in check
mode for personal devices.

Each deploy logs its provenance through logd, which reaches Loki under
`{unit="deploy"}`, and a finished one is announced in the Discord ops
channel; see lib/deploy.sh.

A deploy may restart dropbear and tailscaled or reload the network (a few
seconds off the tailnet, after the deploy has finished), and restart
dnsmasq and logd.

## Packages

The packages the machines need beyond the OpenWrt image are installed by
hand, and the deploy refuses to change anything while one is missing. The
list is `packages` in `default.nix`; on the machine:

```sh
apk update && apk add <package>...
```

## Not managed here

Set on the machine, and never copied off it:

- the root password
- tailscaled's state, which holds the node identity and its `tag:oob` tag
- dropbear's host keys

## First deploy

The deploy reaches the machine through what it installs, so the first one
runs from a personal device over Tailscale SSH on port 22, from a checkout
of this repository:

```sh
nix build .#openwrt
tar -C result/jumpnerr-1 -chf - . | ssh root@jumpnerr-1 '
  rm -rf /tmp/openwrt-deploy && mkdir -m 0700 /tmp/openwrt-deploy &&
  tar -C /tmp/openwrt-deploy -xf - && sh /tmp/openwrt-deploy/apply.sh'
```

After that, `openwrt/deploy` from the development container.
