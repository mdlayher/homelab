#!/bin/sh
# Applies a built OpenWrt configuration on the machine, from the directory
# openwrt/deploy unpacked it into: sets each uci setting and installs each
# file in the manifest that differs from the machine, then does what the
# changes need. With --check it prints the differences and changes nothing,
# exiting 1 if there are any.
set -eu

dir=$(cd "$(dirname "$0")" && pwd)
cd "$dir"
trap 'rm -rf "$dir"' EXIT

check=no
if [ "${1:-}" = --check ]; then
  check=yes
fi

# What the differences found need doing, each named once.
todo=" "
need() {
  case $todo in
  *" $1 "*) ;;
  *) todo="$todo$1 " ;;
  esac
}

while read -r kind key value; do
  [ -n "$kind" ] || continue
  current=$(uci -q get "$key" || true)
  [ "$current" = "$value" ] && continue
  echo "uci: $key: '$current' -> '$value'"
  need "${key%%.*}"
  [ $check = yes ] && continue
  case $kind in
  section | option) uci set "$key=$value" ;;
  list)
    uci -q delete "$key" || true
    for v in $value; do
      uci add_list "$key=$v"
    done
    ;;
  esac
done <settings

# A file's permission bits as ls prints them, and an octal mode spelled the
# same way; OpenWrt's busybox has no stat.
perms() {
  # shellcheck disable=SC2046 # split into ls's fields
  set -- $(ls -ld "$1")
  echo "${1#?}"
}
symbolic() {
  m=$1
  while [ -n "$m" ]; do
    d=${m%"${m#?}"}
    m=${m#?}
    [ $((d & 4)) -ne 0 ] && printf r || printf -
    [ $((d & 2)) -ne 0 ] && printf w || printf -
    [ $((d & 1)) -ne 0 ] && printf x || printf -
  done
  echo
}

while read -r mode path action; do
  src=tree$path
  want=$(symbolic "$mode")
  if [ -f "$path" ] && cmp -s "$src" "$path" && [ "$(perms "$path")" = "$want" ]; then
    continue
  fi
  if [ ! -f "$path" ]; then
    echo "new: $path"
  elif cmp -s "$src" "$path"; then
    echo "mode: $path $(perms "$path") -> $want"
  elif command -v diff >/dev/null; then
    diff -u "$path" "$src" || true
  else
    echo "differs: $path"
  fi
  need "$action"
  [ $check = yes ] && continue
  mkdir -p "$(dirname "$path")"
  cp "$src" "$path"
  chmod "$mode" "$path"
done <manifest

# OpenWrt's tailscale package sets TS_NO_LOGS_NO_SUPPORT in its init
# script, and this tailnet refuses a node that uploads no logs. A package
# upgrade puts the line back.
if grep -q TS_NO_LOGS_NO_SUPPORT /etc/init.d/tailscale; then
  echo "differs: /etc/init.d/tailscale sets TS_NO_LOGS_NO_SUPPORT"
  need tailscale
  [ $check = yes ] || sed -i '/TS_NO_LOGS_NO_SUPPORT/d' /etc/init.d/tailscale
fi

if [ "$todo" = " " ]; then
  echo "up to date"
  exit 0
fi
if [ $check = yes ]; then
  exit 1
fi

later=""
for t in $todo; do
  case $t in
  system)
    uci commit system
    /etc/init.d/system reload
    /etc/init.d/log restart
    ;;
  dhcp)
    uci commit dhcp
    /etc/init.d/dnsmasq restart
    ;;
  firewall)
    uci commit firewall
    /etc/init.d/firewall reload
    ;;
  dropbear)
    uci commit dropbear
    later="$later dropbear"
    ;;
  tailscale) later="$later tailscale" ;;
  esac
done

# Restarting dropbear or tailscaled drops the connection this deploy
# arrived on, so they restart once it has finished, detached from it.
if [ -n "$later" ]; then
  (
    trap '' HUP
    sleep 5
    for s in $later; do
      "/etc/init.d/$s" restart
    done
  ) </dev/null >/dev/null 2>&1 &
  echo "restarting in 5 seconds:$later"
fi

echo "applied"
