#!/usr/bin/env bash
# Applies a built KVM configuration on the device, from the directory
# pikvm/deploy unpacked it into: installs each file in the manifest that
# differs from the device, then does what the changed files need. With
# --check it prints the differences and changes nothing, exiting 1 if there
# are any.
#
# The root filesystem is read-only, so changes happen under rw and the
# filesystem is returned to ro afterwards if that is how it was found.
set -euo pipefail

dir=$(cd "$(dirname "$0")" && pwd)
cd "$dir"
trap 'rm -rf "$dir"' EXIT

check=no
if [[ ${1:-} == --check ]]; then
  check=yes
fi

changed=()
while read -r mode path action; do
  src=tree$path
  if [[ -f $path ]] && cmp -s "$src" "$path" && [[ $(stat -c %a "$path") == "$mode" ]]; then
    continue
  fi
  changed+=("$mode $path $action")

  if [[ ! -f $path ]]; then
    echo "new: $path"
  elif ! grep -Iq . "$src"; then
    echo "differs: $path (binary)"
  elif cmp -s "$src" "$path"; then
    echo "mode: $path $(stat -c %a "$path") -> $mode"
  else
    diff -u --label "$path" --label "$path (new)" "$path" "$src" || true
  fi
done <manifest

# The serve configuration lives in tailscaled's state rather than a file.
serve=ok
status=$(tailscale serve status 2>/dev/null || true)
if ! grep -q 'svc:consrv' <<<"$status" || ! grep -q '127.0.0.1:2222' <<<"$status"; then
  serve=missing
  echo "missing: tailscale serve for svc:consrv"
fi

# consrv's SSH host key is generated on the device and never leaves it.
hostkey=ok
if [[ ! -f /etc/consrv/host_key ]]; then
  hostkey=missing
  echo "missing: /etc/consrv/host_key"
fi

if [[ ${#changed[@]} -eq 0 && $serve == ok && $hostkey == ok ]]; then
  echo "up to date"
  exit 0
fi
if [[ $check == yes ]]; then
  exit 1
fi

if findmnt -no OPTIONS / | tr , '\n' | grep -qx ro; then
  rw >/dev/null
  trap 'ro >/dev/null; rm -rf "$dir"' EXIT
fi

declare -A todo=()
for entry in "${changed[@]}"; do
  read -r mode path action <<<"$entry"
  install -D -m "$mode" "tree$path" "$path"
  todo[$action]=1
done

if [[ $hostkey == missing ]]; then
  install -d -m 0700 /etc/consrv
  ssh-keygen -q -t ed25519 -N "" -C "" -f /etc/consrv/host_key
  todo[consrv]=1
fi

if [[ -n ${todo[consrv]:-} ]]; then
  systemctl daemon-reload
  systemctl enable consrv
  systemctl restart consrv
fi
if [[ -n ${todo[kvmd]:-} ]]; then
  systemctl restart kvmd
fi
if [[ -n ${todo[sshd]:-} ]]; then
  sshd -t
  systemctl reload sshd
fi
if [[ -n ${todo[networkmanager]:-} ]] && systemctl -q is-active NetworkManager; then
  nmcli connection reload
fi

# tailscaled saves the serve configuration to its state file, which needs
# the filesystem writable, so this runs before ro.
if [[ $serve == missing ]]; then
  tailscale serve --service=svc:consrv --tcp=22 tcp://127.0.0.1:2222 >/dev/null
  sync
fi

# Restarting tailscaled drops a deploy that arrived over the tailnet, so it
# is left to systemd until after this script has finished and ro has run.
if [[ -n ${todo[tailscaled]:-} ]]; then
  systemd-run --quiet --collect --on-active=5 --unit=pikvm-deploy-tailscaled systemctl restart tailscaled
  echo "tailscaled restarts in 5 seconds"
fi

echo "applied"
