# shellcheck shell=bash
#
# The network the router firewall test runs in: a namespace for the router
# and one for each thing it faces, each joined to the router by a veth pair
# whose router end carries the production interface name. Sourced by
# run.sh; the plan default.nix renders from the router's configuration
# calls these functions.
#
# Namespaces are held open by a sleeping process and entered through its
# /proc entry, since the build sandbox has no /run for ip netns.

declare -A NS_PID=()
# The MAC of the router's end of each namespace's link.
declare -A ROUTER_MAC=()

die() {
	echo "router-firewall: $*" >&2
	exit 1
}

# Runs a command in namespace $1.
in_ns() {
	local name=$1
	shift
	nsenter --net="/proc/${NS_PID[$name]}/ns/net" -- "$@"
}

# Creates namespace $1. Duplicate address detection would leave a new
# address tentative while the first probe needs it, the kernel's reverse
# path filter would decide cases the ruleset should, and router
# solicitations, which nothing here answers, would repeat into the
# router's counters between cases; all are off before any interface
# exists.
ns_new() {
	local name=$1 pid self
	unshare --net sleep infinity &
	pid=$!
	self=$(readlink /proc/self/ns/net)
	while [[ $(readlink "/proc/$pid/ns/net" 2>/dev/null) == "$self" ]]; do
		kill -0 "$pid" 2>/dev/null || die "cannot create network namespace $name"
		sleep 0.01
	done
	kill -0 "$pid" 2>/dev/null || die "cannot create network namespace $name"
	NS_PID[$name]=$pid
	in_ns "$name" ip link set lo up
	in_ns "$name" sysctl -q -w \
		net.ipv6.conf.all.accept_dad=0 \
		net.ipv6.conf.default.accept_dad=0 \
		net.ipv6.conf.all.router_solicitations=0 \
		net.ipv6.conf.default.router_solicitations=0 \
		net.ipv4.conf.all.rp_filter=0 \
		net.ipv4.conf.default.rp_filter=0
}

ns_cleanup() {
	local pid
	for pid in "${NS_PID[@]}"; do
		kill "$pid" 2>/dev/null || true
	done
}

# Joins namespace $1 at interface $2 to namespace $3 at interface $4.
veth() {
	ip link add "$2" netns "${NS_PID[$1]}" type veth peer name "$4" netns "${NS_PID[$3]}"
}

# Adds each address to interface $2 in namespace $1.
addr() {
	local name=$1 ifname=$2 a
	shift 2
	for a in "$@"; do
		if [[ $a == *:* ]]; then
			in_ns "$name" ip -6 addr replace "$a" dev "$ifname" nodad
		else
			in_ns "$name" ip -4 addr replace "$a" dev "$ifname"
		fi
	done
}

# Routes each prefix via gateway $2 in namespace $1. An IPv4 prefix may
# take an IPv6 gateway, as the dn42 tunnels' do.
#
# A namespace other than the router's reaches its gateway at a permanent
# neighbor entry: neighbor discovery sources a solicitation from the
# packet that needed it, a probe's forged source included, and the router
# drops that, which would stall the namespace's later cases.
route() {
	local name=$1 gw=$2 ifname=$3 p family
	shift 3
	if [[ $name != router ]]; then
		in_ns "$name" ip neigh replace "$gw" lladdr "${ROUTER_MAC[$name]}" dev "$ifname" nud permanent
	fi
	for p in "$@"; do
		family=-4
		[[ $p == *:* || $p == default6 ]] && family=-6
		[[ $p == default4 || $p == default6 ]] && p=default
		if [[ $family == -4 && $gw == *:* ]]; then
			in_ns "$name" ip -4 route add "$p" via inet6 "$gw" dev "$ifname"
		else
			in_ns "$name" ip "$family" route add "$p" via "$gw" dev "$ifname"
		fi
	done
}

up() {
	in_ns "$1" ip link set "$2" up
}

# The router namespace, forwarding both families, with its own addresses
# on lo: the loopbacks, the anycast service addresses and the dn42 ones.
router() {
	ns_new router
	in_ns router sysctl -q -w net.ipv4.ip_forward=1 net.ipv6.conf.all.forwarding=1
	addr router lo "$@"
}

# Sets interface $2 in namespace $1 to generate no link-local address when
# one is among the addresses that follow, so that one is the only one it
# answers at.
lla_only() {
	local name=$1 ifname=$2 a
	shift 2
	for a in "$@"; do
		if [[ $a == fe80:* ]]; then
			in_ns "$name" ip link set "$ifname" addrgenmode none
			return
		fi
	done
}

# A namespace $2 facing the router's interface $1, the namespace's end
# named eth0.
#
#   link IFNAME NS "ROUTER ADDRS" "PEER ADDRS"
link() {
	local ifname=$1 name=$2 mine theirs
	read -ra mine <<<"$3"
	read -ra theirs <<<"$4"
	ns_new "$name"
	veth router "$ifname" "$name" eth0
	ROUTER_MAC[$name]=$(in_ns router ip -j link show "$ifname" | jq -r '.[0].address')
	lla_only router "$ifname" "${mine[@]}"
	lla_only "$name" eth0 "${theirs[@]}"
	addr router "$ifname" "${mine[@]}"
	addr "$name" eth0 "${theirs[@]}"
	up router "$ifname"
	up "$name" eth0
}

# A LAN segment: the router at .1, ::1 and the inventory's link-local, a
# client at .10 and ::10 routing everything through it.
segment() {
	local ifname=$1 v4=$2 ula=$3 lla=$4
	link "$ifname" "$ifname" "$v4.1/24 $ula::1/64 $lla/64" "$v4.10/24 $ula::10/64"
	route "$ifname" "$v4.1" eth0 default4
	route "$ifname" "$lla" eth0 default6
}

# Sets the MAC of namespace $1's link to $2.
mac() {
	in_ns "$1" ip link set eth0 address "$2"
}

# Joins multicast groups on the router's interface $1, the way a listener
# on the router does, so traffic to them reaches its input hook.
join() {
	local ifname=$1
	shift
	in_ns router python3 "$PACKET" join "$ifname" "$@"
}
