#!/usr/bin/env bash
# Deploys a machine from this flake over SSH, building locally.
#
# Usage: nixos/deploy.sh <host> [action] [nixos-rebuild args...]
#
# action is one of switch (default), test, boot, or dry-activate. On the
# router, prefer test first: it activates without a boot entry, so a reboot
# reverts it.
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: $0 <host> [switch|test|boot|dry-activate] [nixos-rebuild args...]" >&2
  exit 2
fi

host=$1
action=${2:-switch}
shift $(( $# >= 2 ? 2 : 1 ))

# root SSH login is only allowed where it's needed for unattended deploys;
# elsewhere log in as matt and escalate with sudo, prompting for the password.
case $host in
  routnerr-3) target=(--target-host "matt@$host" --sudo --ask-sudo-password) ;;
  *) target=(--target-host "root@$host") ;;
esac

cd "$(dirname "$0")/.."
exec nix run --inputs-from . nixpkgs#nixos-rebuild-ng -- \
  "$action" --flake ".#$host" "${target[@]}" "$@"
