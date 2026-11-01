# servnerr-4

This machine is my home server which handles monitoring, hypervisor, and NAS
duties. It's a custom built machine with an AMD Ryzen 9 3900x processor.

## Development containers

`dev.nix` defines NixOS containers on the restricted `dev0` VLAN (see
`nixos/inventory/`), bridged through `br-dev0` on the 10GbE NIC. They reach the
internet and each other, but not the rest of the LAN. Each gets a static lease
and a `<name>.dev.azo.mdlayher.net` record from its inventory entry, and
`mdlayher` can SSH in with the host admin user's key and password.

```sh
# Root shell in a container, from the host.
sudo nixos-container root-login linuxdev

# Container network state, from the host.
sudo nixos-container run linuxdev -- networkctl status eth0

# First time, over SSH: join Tailscale, log in to GitHub so repositories can
# be cloned into ~/src/<repo>/main, and log in to Claude Code (paste the code
# from the browser when prompted).
sudo tailscale up
gh auth login --git-protocol https
gh auth setup-git
gh repo clone mdlayher/homelab ~/src/homelab/main
claude auth login

# Day to day: herdr keeps a persistent terminal workspace on linuxdev
# (herdr-server), starting Claude Code in ~/src on a fresh session; agents
# keep running after detaching (ctrl+b q). Attach inside the container, or
# from a desktop with herdr installed.
herdr
herdr --remote mdlayher@linuxdev.dev.azo.mdlayher.net
```

To add a container: define it with `devContainer` in `dev.nix`, add a `dev0`
host to `nixos/inventory/default.nix` and `secrets.yaml` (placeholder MAC),
deploy, read `eth0`'s MAC with `networkctl status eth0` inside, set it in
`secrets.yaml`, and redeploy the router.

## Off-box backup

`rclone-backup.nix` copies the irreplaceable data under `/primary` to Google
Drive every night; its `paths` list names what is included. Tarsnap separately
backs up `/primary/archive` (see `storage.nix`).

The backup runs as an unprivileged user that sees only those paths, so every
file and directory in them must stay world-readable. A file or directory that
isn't fails the run and alerts; `chmod a+rX` on it fixes the next run.

The `backup` crypt remote wraps the `gdrive` drive remote's `homelab-backup`
folder, so Drive holds encrypted file and directory names and contents. Paths
on `backup:` are paths below `/primary`: `/primary/media/photos` is
`backup:media/photos`. The copy never deletes from the remote, so files removed
here remain there. A complete copy on a Sunday is followed by a check that reads
the whole set from `primary` at idle I/O priority, so the pool sees a full read
of it each week.

The Drive token comes from an OAuth client of my own, authorized on the
workstation with the `drive.file` scope, which limits the token to files this
client created. `rclone authorize` takes that configuration as unpadded base64
JSON and prints its answer the same way, with the token inside:

```sh
rclone authorize drive "$(printf '%s' '{"client_id":"<id>","client_secret":"<secret>","scope":"drive.file"}' | base64 -w0 | tr -d =)"
jq -rn --arg b '<pasted answer>' '$b | @base64d | fromjson | .token'
```

The client's consent screen must be published "In production": a client left in
"Testing" issues refresh tokens that expire after seven days, after which every
run fails until the token is minted again. The unverified-app warning during
authorization is expected for a personal client. The `homelab-backup` folder
must be created by rclone, which the first run does; a folder made in the Drive
web interface is invisible to this client.

To restore, run rclone as root on the server with a copy of the rendered
config, which holds both remotes. rclone writes refreshed tokens back into its
config, so it gets a copy rather than the original, and files it restores are
owned by root until handed back:

```sh
conf=$(sudo mktemp)
sudo install -m 0600 /run/secrets/rendered/rclone-backup.conf "$conf"

# List what the remote holds under a directory.
sudo rclone --config "$conf" lsf backup:media/photos

# Restore one file or directory.
sudo rclone --config "$conf" copy -v backup:misc/parents.tar.gz /primary/misc/

# Restore the whole set.
sudo rclone --config "$conf" copy -v backup: /primary

sudo rm "$conf"
sudo chown -R <owner>:<group> <restored path>
```

Elsewhere, build the same config from the `rclone/*` keys in this machine's
`secrets.yaml`. Under `drive.file` the files are visible only to the OAuth
client that created them, so a restore through rclone needs the client id and
secret too. Without them, the encrypted files can still be downloaded from the
Drive web interface and decrypted through a crypt remote over the local
download. The crypt password and salt are the only way to decrypt the remote,
and losing them loses the backup, so keep them and the OAuth client id and
secret in the password manager as well.
