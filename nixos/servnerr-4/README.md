# servnerr-4

This machine is my home server which handles monitoring, hypervisor, and NAS
duties. It's a custom built machine with an AMD Ryzen 9 3900x processor.

## Development containers

`dev.nix` defines NixOS containers on the restricted `dev0` VLAN (see
`nixos/inventory/`), bridged through `br-dev0` on the 10GbE NIC. They reach the
internet and each other, but not the rest of the LAN. Each gets a static lease
and a `<name>.dev.lan.servnerr.com` record from its inventory entry, and matt
can SSH in with the same key and password as the host.

```sh
# Root shell in a container, from the host.
sudo nixos-container root-login linuxdev

# Container network state, from the host.
sudo nixos-container run linuxdev -- networkctl status eth0

# First time: join Tailscale, then log in to Claude Code over SSH (paste the
# code from the browser when prompted) and run it in tmux so the Claude app
# can attach to the session with Remote Control.
sudo tailscale up
tmux new -s claude claude
```

To add a container: define it with `devContainer` in `dev.nix`, add a `dev0`
host to `nixos/inventory/default.nix` and `secrets.yaml` (placeholder MAC),
deploy, read `eth0`'s MAC with `networkctl status eth0` inside, set it in
`secrets.yaml`, and redeploy the router.
