# windows

The Windows PCs listed in `hosts.nix`, each running the exporters the
server's Prometheus scrapes from them. They run Windows rather than NixOS,
so this directory builds what the repository manages on them and `deploy`
applies it over SSH. Nothing applies it nightly.

- `hosts.nix`: the machines and the exporter ports, read by the server's
  Prometheus as well.
- `default.nix`: the winget packages at pinned versions, the services and
  firewall rules for the exporters and ping, the admin's SSH keys from
  `nixos/ssh-keys.nix`, and HWiNFO's settings, with the HWiNFO exporter
  built from `go/internal/hwinfo_exporter`. Built as `.#windows`. apply.ps1
  also keeps sshd's password logins off and IPv6 addresses derived from the
  adapter's MAC, which the inventory's records for these machines assume.
- Configuration files: windows_exporter's collectors, and Alloy's, which
  ships the Application, System and OpenSSH event logs to Loki through
  `loki.svc` under `{job="windows-eventlog"}`, labeled by `host` and
  `channel`. The clock syncs from the anycast NTP address.
- `apply.ps1`: runs on the machine; installs or upgrades what differs from
  the pins, creates what is missing, and starts what is stopped.
- `deploy`: builds, uploads and applies over SSH as the admin, to one
  machine or, with `--all`, to every machine in `hosts.nix` that is on.
  Windows ships no logs, so it sends each deploy's provenance to Loki
  itself, under `{unit="deploy"}`, and a finished one is announced in the
  Discord ops channel; see lib/deploy.sh.
- `secrets.yaml`: HWiNFO's license key, which `deploy` installs. It
  decrypts with the admin's key or the development container's own, so a
  deploy needs no gate.

```sh
# Show how the machines differ from this checkout; changes nothing.
windows/deploy --check --all

# Apply to every machine, or to one.
windows/deploy --all
windows/deploy gamnerr-1
```

To upgrade a package, bump its version in `default.nix` and deploy. winget
stops the package's services or processes while it replaces their files.

## Not managed here

- Windows itself, its updates and the NVIDIA driver.
- Installing OpenSSH Server and the first copy of the admin's keys, which a
  deploy needs before it can log in: see Setting up a machine. Deploys keep
  the keys and sshd's settings in step after that.
- The tailnet: each machine joins it, then gets `tag:windows` in the admin
  console.
- Network adapter settings.

## Setting up a machine

1. Join the tailnet and give the machine `tag:windows`.
2. In an elevated PowerShell, install OpenSSH Server, put the admin's FIDO2
   keys from `nixos/ssh-keys.nix` in
   `C:\ProgramData\ssh\administrators_authorized_keys` readable only by
   Administrators and SYSTEM, turn off password logins in `sshd_config`
   above its `Match Group administrators` block, and set PowerShell as the
   default shell. sshd writes `sshd_config` on its first start, so start it
   once before editing the file.
3. Add the machine to `hosts.nix`, deploy the server so Prometheus scrapes
   it, then `windows/deploy` the machine.
4. Open HWiNFO once from the Start menu and accept the UAC prompt. With
   Autorun set, it writes its own launcher and points its logon task at it.
   HWiNFO needs an elevated token, which a task started over SSH does not
   get, so the task `apply.ps1` registers when none exists cannot start it
   until then.
