# monitnerr-1

Raspberry Pi 4 Model B Rev 1.2 serial console server, replacing the previous
gokrazy deployment in `gokrazy/monitnerr-1/`. Runs
[consrv](https://github.com/mdlayher/consrv) (built from source in
`consrv.nix`; not packaged in nixpkgs) with USB serial adapters attached to the
router and server, plus the usual base system: node_exporter and Tailscale.

## Bootstrap

The Pi boots the standard NixOS aarch64 SD image layout: Pi firmware and
U-Boot on the `FIRMWARE` partition, extlinux from the `NIXOS_SD` root. The
mainline kernel from common.nix drives the Pi 4 fine and comes from the NixOS
binary cache.

1. Flash the latest NixOS aarch64 SD (installer) image to the SD card, boot
   the Pi, and get SSH access.
2. Adopt the Pi into the network inventory (the previous gokrazy Pi was
   removed): declare `monitnerr-1.ipv6 = "eui64"` on `mgmt0` in
   `nixos/inventory/default.nix`, and add its `mac`, `ipv4`, and `iid` to
   `nixos/inventory/secrets.yaml`, computing the EUI-64 IID from the MAC with
   the `lib.nix` helper; see nixos/README.md. Deploy the router to publish
   DHCP and DNS records.
3. Add the machine's SSH host key as a sops recipient, so that the user
   password hashes in `nixos/secrets/common.yaml` (required at activation) and
   the inventory secrets can be decrypted:

   ```sh
   ssh-keyscan monitnerr-1 | ssh-to-age
   # Add the age key to .sops.yaml for common.yaml and inventory secrets, then:
   sops updatekeys nixos/secrets/common.yaml
   sops updatekeys nixos/inventory/secrets.yaml
   ```

4. Deploy: `nixos/deploy monitnerr-1 boot`, then reboot into the new
   system.
5. Verify `hardware-configuration.nix` against `nixos-generate-config` output
   on the machine.
6. `tailscale up` to join the tailnet.

## Notes

- CI (`.github/workflows/nix.yml`) evaluates this configuration via
  `nix flake check`, but the build matrix only covers the x86_64 machines; the
  full closure builds on the Pi itself during deploys.
- The consrv SSH host key is generated on first start at
  `/var/lib/consrv/host_key`; expect a host key change relative to the gokrazy
  deployment when connecting to the console ports.
