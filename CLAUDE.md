# CLAUDE.md

Guidance for agents working in this repository.

## Ground rules

- Never commit or push without explicit approval; Matt drives git.
- Agent sessions usually run inside the `linuxdev` container on servnerr-4.
  Deploys to servnerr-4 do not restart it (`restartIfChanged = false`), but
  changes to its container scaffolding (bind mounts, networking, tun) need a
  manual restart, which kills the session — flag those before deploying.

## Deploys and upgrades

- `nixos/deploy.sh <host>` deploys from the local checkout and prompts for a
  sudo password: it must run in a real terminal. Agent-driven shells cannot
  answer the prompt (and would echo the password); ask Matt to run it.
- `system.autoUpgrade` applies origin/main to every machine nightly (~04:00).
  Anything merged to main deploys itself within a day — deploy from the local
  tree first, then merge, or be ready for the nightly to apply it.
- Do not trigger `nixos-upgrade.service` right after a push: the GitHub flake
  tarball is cached (~1h TTL) and can apply a stale main. Deploy from a local
  checkout instead, or wait out the TTL.
- On the router, always `deploy.sh routnerr-3 test` first (a reboot reverts
  it), verify, then `boot` or `switch`. Serial consoles for the router and
  server are reachable via consrv on the monitor if SSH is lost.
- To prove a refactor is a no-op, compare
  `nix eval --raw .#nixosConfigurations.<host>.config.system.build.toplevel.drvPath`
  before and after: identical drv paths mean identical systems.

## Secrets (sops)

- Renaming or removing a secret key must land in the SAME commit as every Nix
  reference to it, or nightly activation fails (sops-nix aborts on a missing
  declared key). Recipients are unchanged by edits, so no `updatekeys`.
- The admin age key lives at `~/.config/sops/age/keys.txt` (also inside
  linuxdev). For scripted edits without printing plaintext, use sed as the
  editor: `EDITOR="sed -i s/old:/new:/" sops <file>`.
- Secrets with `neededForUsers` decrypt before users are created; user
  password hashes must stay in that set.

## Users

- The admin user is `homelab.user` in `nixos/modules/common.nix` (uid 1000,
  group `users`). Keep uid 1000 in any future rename so file ownership never
  changes, and never declare two users with the same uid — no assertion
  catches the ambiguous passwd entries it produces.

## Style

- Prose and comments refer to machines by role — the server, the router, the
  monitor, the workstation — not by hostname. Hostnames appear only in
  functional configuration (inventory, flake attrs, probe targets).
