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
# Paths built locally are unsigned and matt is not a trusted user there, so
# also build on the machine itself: only derivations and sources are copied,
# and everything else comes from the binary cache.
case $host in
  routnerr-3) target=(--build-host "matt@$host" --target-host "matt@$host" --sudo --ask-sudo-password) ;;
  *) target=(--target-host "root@$host") ;;
esac

# Flakes may not be enabled in the local nix.conf (e.g. on a non-NixOS host).
export NIX_CONFIG="${NIX_CONFIG:+$NIX_CONFIG
}experimental-features = nix-command flakes"

cd "$(dirname "$0")/.."
exec nix run --inputs-from . nixpkgs#nixos-rebuild-ng -- \
  "$action" --flake ".#$host" "${target[@]}" "$@"
