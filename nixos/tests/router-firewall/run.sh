# shellcheck shell=bash
#
# Runs the router firewall cases. Builds the network from the plan, loads
# the router's ruleset and the test's set elements into the router's
# namespace, then for each case sends its probe and checks the verdict
# against the router's named counters, read before and after, and against
# what arrived at the far end.
#
# Every namespace carries a sink table counting what its input hook
# admitted, by protocol and port, after any filter in that namespace; a
# probe that reached it was delivered. Each case runs alone and every
# counter is compared, so a case passes only if the expected counter moved
# and no other did.
set -euo pipefail

: "${TOPOLOGY:?}" "${PLAN:?}" "${RULESET:?}" "${ELEMENTS:?}" "${SINK:?}" "${CASES:?}" "${PACKET:?}"
export PACKET

# shellcheck source=topology.sh
source "$TOPOLOGY"
trap ns_cleanup EXIT

# shellcheck disable=SC1090
source "$PLAN"

# Multicast listener reports from the new interfaces repeat for about a
# second after each join; let them pass before anything is counted.
sleep 2

in_ns router nft -f "$RULESET"
in_ns router nft -f "$ELEMENTS"
for name in "${!NS_PID[@]}"; do
	in_ns "$name" nft -f "$SINK"
done

# Named counters in the router's filter table, as "name packets" lines.
counters() {
	in_ns router nft -j list counters table inet filter |
		jq -r '.nftables[] | .counter? // empty | "\(.name) \(.packets)"'
}

# Packets counted by the rules carrying comment $1. A comment no counted
# rule carries is an error rather than zero, so a case cannot pass by
# naming a rule that does not exist.
rule_packets() {
	in_ns router nft -j list table inet filter |
		jq -e --arg c "$1" '
			[.nftables[] | .rule? // empty | select(.comment == $c)
			  | .expr[] | .counter? // empty | objects | .packets]
			| if length == 0 then error("no counted rule has comment \"\($c)\"") else add end'
}

# Sends a case's probe from namespace $1; the exit status is the probe's.
probe() {
	local from=$1 src=$2 dst=$3 kind=$4 port=$5 sport=$6
	local -a s=() p=()
	if [[ $src != - ]]; then
		s=(-s "$src")
	fi
	if [[ $sport != - ]]; then
		p=(-p "$sport")
	fi
	# nc needs the interface a link-local destination is reached on.
	local scoped=$dst
	if [[ $dst == ff02:* || $dst == fe80:* ]]; then
		scoped=$dst%eth0
	fi
	# TCP and UDP probes end before TCP's first retransmission at one
	# second, so a dropped SYN is never resent into the next case.
	case $kind in
	tcp) in_ns "$from" timeout 0.5 nc -z "${s[@]}" "${p[@]}" "$scoped" "$port" </dev/null ;;
	udp) printf probe | in_ns "$from" timeout 0.5 nc -u "${s[@]}" "${p[@]}" "$scoped" "$port" ;;
	ping)
		if [[ $src != - ]]; then
			s=(-I "$src")
		fi
		in_ns "$from" ping -n -q -c1 -W1 "${s[@]}" "$dst" >/dev/null
		;;
	echo-hbh) in_ns "$from" python3 "$PACKET" echo-hbh "$src" "$dst" ;;
	mld) in_ns "$from" python3 "$PACKET" mld "$dst" eth0 ;;
	dhcp-discover) in_ns "$from" python3 "$PACKET" dhcp-discover eth0 ;;
	*) die "unknown probe $kind" ;;
	esac
}

failed=0
total=0
start=$SECONDS
printf '%-6s %-46s %-36s %s\n' RESULT CASE EXPECTED OBSERVED

while IFS=$'\t' read -r -u 3 name from to src dst kind port sport verdict what; do
	total=$((total + 1))
	in_ns "$to" nft flush set inet sink seen

	declare -A before=() after=()
	while read -r c n; do before[$c]=$n; done < <(counters)
	rule_before=0
	if [[ $verdict == accept && $what != - ]]; then
		rule_before=$(rule_packets "$what")
	fi

	status=0
	probe "$from" "$src" "$dst" "$kind" "$port" "$sport" >/dev/null 2>&1 || status=$?

	# Whether the probe arrived: by the sink for TCP and UDP, by the reply
	# for an echo, and not observable for a listener report.
	case $kind in
	tcp | udp | dhcp-discover)
		proto=$kind
		[[ $kind == dhcp-discover ]] && proto=udp
		if in_ns "$to" nft get element inet sink seen "{ $proto . $port }" >/dev/null 2>&1; then
			delivered=yes
		else
			delivered=no
		fi
		;;
	ping | echo-hbh)
		delivered=no
		[[ $status == 0 ]] && delivered=yes
		;;
	*) delivered=- ;;
	esac

	while read -r c n; do after[$c]=$n; done < <(counters)
	moved=()
	for c in "${!after[@]}"; do
		if ((after[$c] > ${before[$c]:-0})); then
			moved+=("$c")
		fi
	done
	moved_list=${moved[*]:-none}

	ok=yes
	if [[ $verdict == accept ]]; then
		expected=accept
		[[ $what != - ]] && expected="accept: $what"
		[[ ${#moved[@]} == 0 && $delivered != no ]] || ok=no
		if [[ $what != - ]] && (($(rule_packets "$what") <= rule_before)); then
			ok=no
		fi
	else
		expected="$verdict: $what"
		[[ $moved_list == "$what" && $delivered != yes ]] || ok=no
	fi

	result=PASS
	if [[ $ok == no ]]; then
		result=FAIL
		failed=$((failed + 1))
	fi
	printf '%-6s %-46s %-36s counters: %s, delivered: %s\n' \
		"$result" "$name" "$expected" "$moved_list" "$delivered"
	unset before after
done 3<"$CASES"

echo "router-firewall: $((total - failed))/$total cases passed in $((SECONDS - start))s"
((failed == 0))
