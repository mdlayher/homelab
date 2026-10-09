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

# Deletes each section of a config's type whose option holds a value: "absent
# firewall.zone name=lan". Sections are found by uci's stable IDs, so
# deleting one does not renumber the rest.
absent() {
  cfg=${1%%.*}
  type=${1#*.}
  opt=${2%%=*}
  val=${2#*=}
  for s in $(uci -X show "$cfg" | sed -n "s/^$cfg\.\([^.=]*\)=$type\$/\1/p"); do
    [ "$(uci -q get "$cfg.$s.$opt" || true)" = "$val" ] || continue
    echo "uci: $cfg.$s: $type with $opt '$val' -> deleted"
    need "$cfg"
    [ $check = yes ] || uci delete "$cfg.$s"
  done
}

while read -r kind key value; do
  [ -n "$kind" ] || continue
  case $kind in
  absent)
    absent "$key" "$value"
    continue
    ;;
  unset)
    current=$(uci -q get "$key" || true)
    [ -n "$current" ] || continue
    echo "uci: $key: '$current' -> unset"
    need "${key%%.*}"
    [ $check = yes ] || uci delete "$key"
    continue
    ;;
  esac
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
    /etc/init.d/odhcpd reload
    ;;
  firewall)
    uci commit firewall
    /etc/init.d/firewall reload
    ;;
  network)
    uci commit network
    later="$later network"
    ;;
  dropbear)
    uci commit dropbear
    later="$later dropbear"
    ;;
  tailscale) later="$later tailscale" ;;
  esac
done

# Restarting dropbear or tailscaled drops the connection this deploy
# arrived on, and reloading the network can reconfigure its interface, so
# they run once it has finished, detached from it.
if [ -n "$later" ]; then
  (
    trap '' HUP
    sleep 5
    for s in $later; do
      case $s in
      network) /etc/init.d/network reload ;;
      *) "/etc/init.d/$s" restart ;;
      esac
    done
  ) </dev/null >/dev/null 2>&1 &
  echo "reloading or restarting in 5 seconds:$later"
fi

echo "applied"
