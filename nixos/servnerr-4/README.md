# servnerr-4

This machine is my home server which handles monitoring, hypervisor, and NAS
duties. It's a custom built machine with an AMD Ryzen 9 3900x processor.

## Development containers

`dev.nix` defines NixOS containers on the restricted `dev0` VLAN (see
`nixos/inventory/`), bridged through `br-dev0` on the 10GbE NIC. They reach the
internet and each other, but not the rest of the LAN. Each gets a static lease
and a `<name>.dev.lan.servnerr.com` record from its inventory entry, and
`mdlayher` can SSH in with matt's key and password from the host.

```sh
# Root shell in a container, from the host.
sudo nixos-container root-login linuxdev

# Container network state, from the host.
sudo nixos-container run linuxdev -- networkctl status eth0

# First time, over SSH: join Tailscale, log in to GitHub so the dev-repos
# service can clone into ~/src, and log in to Claude Code (paste the code from
# the browser when prompted). The claude-remote-control service then runs
# Claude Code in server mode inside a tmux session on its own tmux server
# (so byobu never attaches to it) for the Claude app to attach sessions to;
# `tmux -L claude attach` shows it.
sudo tailscale up
gh auth login --git-protocol https
sudo systemctl start dev-repos
claude auth login
sudo systemctl start claude-remote-control

# Day to day: herdr keeps a persistent terminal workspace on linuxdev
# (herdr-server); agents keep running after detaching (ctrl+b q). Attach
# inside the container, or from a desktop with herdr installed.
herdr
herdr --remote mdlayher@linuxdev.dev.lan.servnerr.com
```

To add a container: define it with `devContainer` in `dev.nix`, add a `dev0`
host to `nixos/inventory/default.nix` and `secrets.yaml` (placeholder MAC),
deploy, read `eth0`'s MAC with `networkctl status eth0` inside, set it in
`secrets.yaml`, and redeploy the router.
