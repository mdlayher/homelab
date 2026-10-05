# lgtv

The LG TVs listed in `hosts.nix`, rooted with the Homebrew Channel and
running [Glasshouse](https://github.com/rorygallagher2024/lg-webos-dashboard),
whose stats the server's Prometheus scrapes. They run webOS rather than
NixOS, so this directory builds what the repository manages on them and
`deploy` applies it over SSH. Nothing applies it nightly.

- `hosts.nix`: the TVs and Glasshouse's port, read by the router's firewall
  and the server's Prometheus as well.
- `default.nix`: root's `authorized_keys`, the admin's FIDO2 keys from
  `nixos/ssh-keys.nix`, so every login takes a YubiKey touch.
  Built as `.#lgtv`.
- `apply.sh`: runs on the TV; installs what differs.
- `settings.js`: merges the Glasshouse settings `default.nix` manages into
  its `config.json`, on the TV with Glasshouse's node, and leaves every
  other key alone. A changed setting restarts Glasshouse.
- `deploy`: builds and applies over SSH as root. The TVs ship no logs, so
  it sends each deploy's provenance to Loki itself, under
  `{unit="deploy"}`, and a finished one is announced in the Discord ops
  channel; see lib/deploy.sh.
- `secrets.yaml`: the one Glasshouse token every TV is set to in its
  dashboard, which the server's json exporter sends as a bearer token to
  each. It decrypts with the admin's key or the server's; edit it from
  the container through the gate.

```sh
# Show how the TVs differ from this checkout; changes nothing.
lgtv/deploy --check

# Apply.
lgtv/deploy
```

The TVs are on their own restricted VLAN (see `nixos/inventory/`): they
reach the internet and the router's DNS and NTP, nothing on another LAN.
The router admits SSH, the Homebrew Channel's telnet, Glasshouse's port
and developer mode's SSH and key server on them from the development
container alone, so `deploy` runs from there.

## Not managed here

Installed or set on the TV, and never copied off it:

- the Homebrew Channel and its settings: SSH on, telnet off, updates
  blocked
- Glasshouse itself, installed by its own `server/deploy.sh` from a
  checkout of a release tag, and the settings in
  `/var/lib/tvweb/config.json` that `default.nix` does not manage, set in
  its dashboard or by hand; its token is the one in `secrets.yaml`
- the dropbear host key

## Setting up a TV

1. Root it and install the Homebrew Channel. Leave the TV off the
   internet, or at least with automatic updates off: a firmware update can
   close the root exploit.
2. Over the Homebrew Channel's telnet, install the admin's FIDO2 keys from
   `nixos/ssh-keys.nix` into `/home/root/.ssh/authorized_keys`, turn SSH on
   and reboot, confirm a key login, then turn telnet off.
3. Install Glasshouse with its `server/deploy.sh <address>`.
4. Add the TV to the inventory and `hosts.nix`, then `lgtv/deploy`.
