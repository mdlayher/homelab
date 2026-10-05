#!/bin/sh
# Applies a built TV configuration on the TV, from the directory lgtv/deploy
# unpacked it into: installs each file in the manifest that differs from the
# TV and merges the managed settings into Glasshouse's config.json. With
# --check it prints the differences and changes nothing, exiting 1 if there
# are any.
#
# POSIX sh, for webOS's BusyBox.
set -eu

dir=$(cd "$(dirname "$0")" && pwd)
cd "$dir"
trap 'rm -rf "$dir"' EXIT

check=no
if [ "${1:-}" = --check ]; then
  check=yes
fi

changed=no
while read -r mode path; do
  src=tree$path
  if [ -f "$path" ] && cmp -s "$src" "$path" && [ "$(stat -c %a "$path")" = "$mode" ]; then
    continue
  fi
  changed=yes

  if [ ! -f "$path" ]; then
    echo "new: $path"
  elif cmp -s "$src" "$path"; then
    echo "mode: $path $(stat -c %a "$path") -> $mode"
  else
    diff -u "$path" "$src" || true
  fi

  if [ $check = no ]; then
    mkdir -p "$(dirname "$path")"
    cp "$src" "$path.new"
    chmod "$mode" "$path.new"
    mv -f "$path.new" "$path"
  fi
done <manifest

# Glasshouse reads config.json only at start, so a changed setting restarts
# it. Its install is by hand (see README.md), so a TV without it takes the
# files above and is reported as differing.
tvwebctl=/var/lib/tvweb/tvwebctl
config=/var/lib/tvweb/config.json
if [ ! -x $tvwebctl ]; then
  echo "glasshouse: not installed, no $tvwebctl; settings skipped"
  [ $check = yes ] && exit 1
  exit 0
fi
if [ $check = yes ]; then
  diffs=$(/usr/bin/node settings.js --check settings.json $config)
else
  diffs=$(/usr/bin/node settings.js settings.json $config)
fi
if [ -n "$diffs" ]; then
  changed=yes
  echo "$diffs"
  if [ $check = no ]; then
    $tvwebctl restart
  fi
fi

if [ $changed = no ]; then
  echo "up to date"
elif [ $check = yes ]; then
  exit 1
fi
