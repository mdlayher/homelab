#!/usr/bin/env bash
# Applies a built Home Assistant configuration on the appliance, from the
# directory hass/deploy unpacked it into: installs each file in /config
# that differs and posts each add-on's options that differ to the
# Supervisor, then checks and restarts what changed: core for its own
# configuration, and each add-on whose options or files changed. With
# --check it prints the differences and changes nothing, exiting 1 if there
# are any.
set -euo pipefail

dir=$(cd "$(dirname "$0")" && pwd)
cd "$dir"
trap 'rm -rf "$dir"' EXIT

check=no
if [[ ${1:-} == --check ]]; then
  check=yes
fi

supervisor() {
  local path=$1
  shift
  curl -sfS -H "Authorization: Bearer $SUPERVISOR_TOKEN" "$@" "http://supervisor$path"
}

# What each managed add-on's restart is, "now" or "later", from the build.
declare -A restart_of=()
while read -r slug restart; do
  restart_of[$slug]=$restart
done <addons

# The add-ons to restart and whether core's configuration changed.
declare -A restarts=()
core=no

changed_files=()
while read -r path action; do
  if [[ -f /config/$path ]] && cmp -s "tree/$path" "/config/$path"; then
    continue
  fi
  changed_files+=("$path")
  if [[ $action == core ]]; then
    core=yes
  else
    restarts[$action]=1
  fi
  if [[ ! -f /config/$path ]]; then
    echo "new: /config/$path"
  else
    diff -u -L "/config/$path" -L "/config/$path (new)" "/config/$path" "tree/$path" || true
  fi
done <files

changed_addons=()
while read -r slug _; do
  mkdir -p current wanted
  # Only the options the build declares; the rest keep the add-on's
  # defaults.
  supervisor "/addons/$slug/info" |
    jq -S --slurpfile want "tree/addons/$slug.json" \
      '.data.options | with_entries(select(.key as $k | $want[0] | has($k)))' >"current/$slug.json"
  jq -S . "tree/addons/$slug.json" >"wanted/$slug.json"
  if cmp -s "current/$slug.json" "wanted/$slug.json"; then
    continue
  fi
  changed_addons+=("$slug")
  restarts[$slug]=1
  diff -u -L "$slug options" -L "$slug options (new)" \
    "current/$slug.json" "wanted/$slug.json" || true
done <addons

if [[ ${#changed_files[@]} -eq 0 && ${#changed_addons[@]} -eq 0 ]]; then
  echo "up to date"
  exit 0
fi
if [[ $check == yes ]]; then
  exit 1
fi

# A configuration Home Assistant rejects is put back as it was, so the
# next start of core never loads it.
if [[ ${#changed_files[@]} -gt 0 ]]; then
  mkdir -p previous
  for path in "${changed_files[@]}"; do
    if [[ -f /config/$path ]]; then
      install -D -m 0644 "/config/$path" "previous/$path"
    fi
    install -D -m 0644 "tree/$path" "/config/$path"
  done
  if [[ $core == yes ]] && ! ha core check; then
    for path in "${changed_files[@]}"; do
      if [[ -f previous/$path ]]; then
        install -m 0644 "previous/$path" "/config/$path"
      else
        rm -f "/config/$path"
      fi
    done
    echo "error: ha core check failed; /config is as it was" >&2
    exit 1
  fi
fi

for slug in "${changed_addons[@]}"; do
  jq -c '{options: .}' "tree/addons/$slug.json" |
    supervisor "/addons/$slug/options" -X POST -H 'Content-Type: application/json' --data-binary @- >/dev/null
done

later=()
for slug in "${!restarts[@]}"; do
  if [[ ${restart_of[$slug]:-now} == later ]]; then
    later+=("$slug")
  else
    supervisor "/addons/$slug/restart" -X POST >/dev/null
    echo "restarted $slug"
  fi
done

if [[ $core == yes ]]; then
  ha core restart
  echo "restarted core"
fi

# Restarting an add-on the deploy runs through drops its connection, so
# those restarts are left to a detached process that starts once this
# script has finished. This add-on's own restart ends that process, so it
# comes last.
if [[ ${#later[@]} -gt 0 ]]; then
  self=$(supervisor /addons/self/info | jq -r .data.slug)
  ordered=()
  for slug in "${later[@]}"; do
    [[ $slug == "$self" ]] || ordered+=("$slug")
  done
  for slug in "${later[@]}"; do
    [[ $slug != "$self" ]] || ordered+=("$slug")
  done
  # shellcheck disable=SC2016 # expanded by the detached shell
  setsid bash -c '
    sleep 5
    for slug; do
      curl -sfS -X POST -H "Authorization: Bearer $SUPERVISOR_TOKEN" "http://supervisor/addons/$slug/restart"
    done' bash "${ordered[@]}" </dev/null >/dev/null 2>&1 &
  echo "${ordered[*]} restart in 5 seconds"
fi

echo "applied"
