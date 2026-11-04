#!/usr/bin/env bash
# Compares the CyberPower cards with the built configuration over SNMPv3
# and, without --check, sets what differs. Run by cyberpower/deploy
# through the gate, as the gate's user, which supplies the SNMPv3
# credentials in the environment; it reads nothing of the repository.
#
# Usage: apply.sh [--check] <host>...
#
# Prints each difference as `<object> <current> -> <desired>` under a
# `== <host>` header, and ends each host with `result <host> ok|failed`
# for cyberpower/deploy's provenance. Exits 1 if any host differs under
# --check or failed.
set -euo pipefail

check=0
if [[ ${1:-} == --check ]]; then
  check=1
  shift
fi
tree=$(dirname "$0")
export PATH=@netSnmp@/bin:$PATH

for v in CYBERPOWER_SNMPV3_USER CYBERPOWER_SNMPV3_AUTH_KEY CYBERPOWER_SNMPV3_PRIV_KEY; do
  if [[ -z ${!v:-} ]]; then
    echo "apply.sh: $v is unset; run cyberpower/deploy, which supplies it through the gate" >&2
    exit 2
  fi
done

# The credentials reach net-snmp through a configuration file readable by
# this user alone rather than on its command lines, where any user's ps
# would show them. SNMPCONFPATH and SNMP_PERSISTENT_DIR keep net-snmp to
# that directory, reading and writing nothing else.
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
(
  umask 077
  cat >"$stage/snmp.conf" <<EOF
defVersion 3
defSecurityLevel authPriv
defSecurityName $CYBERPOWER_SNMPV3_USER
defAuthType SHA
defAuthPassphrase $CYBERPOWER_SNMPV3_AUTH_KEY
defPrivType AES
defPrivPassphrase $CYBERPOWER_SNMPV3_PRIV_KEY
EOF
)
export SNMPCONFPATH=$stage SNMP_PERSISTENT_DIR=$stage MIBS=

declare -A names targets
while read -r oid name; do names[$oid]=$name; done <"$tree/names"
while read -r host target; do targets[$host]=$target; done <"$tree/targets"

# read_current <target> <oid...>: reads the objects into current, by OID,
# as net-snmp prints them with the quotes around a string removed.
# default.nix admits no quote or backslash in a desired string, so an
# escaped one on the card shows as a difference. The objects go in
# requests of 20, which keeps each response well inside the message size
# a small embedded agent accepts.
declare -A current
read_current() {
  local target=$1 response oid value i
  shift
  current=()
  for ((i = 1; i <= $#; i += 20)); do
    # -On numeric OIDs, -Oq no type, -Oe integers bare, -Oa strings as text.
    response=$(snmpget -On -Oq -Oe -Oa "$target" "${@:i:20}") || return 1
    while read -r oid value; do
      if [[ $value == \"*\" ]]; then
        value=${value:1:-1}
      fi
      current[${oid#.}]=$value
    done <<<"$response"
  done
}

# diff_desired <host>: compares the host's desired state with current,
# printing each difference and collecting it as snmpset arguments in sets.
sets=()
diff_desired() {
  local host=$1 oid type value show
  sets=()
  while read -r oid type value; do
    if [[ ${current[$oid]-} != "$value" ]]; then
      show=("${current[$oid]-(missing)}" "$value")
      if [[ $type == s ]]; then
        show=("\"${current[$oid]-}\"" "\"$value\"")
        [[ -v current[$oid] ]] || show[0]="(missing)"
      fi
      echo "${names[$oid]:-$oid} ${show[0]} -> ${show[1]}"
      sets+=("$oid" "$type" "$value")
    fi
  done <"$tree/$host"
}

failed=0
for host in "$@"; do
  echo "== $host"
  target=${targets[$host]}
  mapfile -t oids < <(cut -d' ' -f1 "$tree/$host")

  status=0
  if ! read_current "$target" "${oids[@]}"; then
    echo "$host: could not read the card" >&2
    status=1
  else
    diff_desired "$host"
    if [[ ${#sets[@]} -gt 0 && $check -eq 1 ]]; then
      status=1
    elif [[ ${#sets[@]} -gt 0 ]]; then
      # One request sets every difference, then a read confirms each took.
      if ! snmpset -On -Oq "$target" "${sets[@]}" >/dev/null; then
        echo "$host: the card refused the set" >&2
        status=1
      elif ! read_current "$target" "${oids[@]}"; then
        echo "$host: could not read the card back" >&2
        status=1
      else
        diff_desired "$host" >"$stage/after"
        if [[ ${#sets[@]} -gt 0 ]]; then
          echo "$host: the set did not take:" >&2
          cat "$stage/after" >&2
          status=1
        fi
      fi
    fi
  fi

  if [[ $status -eq 0 ]]; then
    echo "result $host ok"
  else
    echo "result $host failed"
    failed=1
  fi
done
exit "$failed"
