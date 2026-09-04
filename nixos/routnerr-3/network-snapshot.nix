# Periodic snapshots of the router's neighbor, address, route and DHCP lease
# state, written to the journal as JSON and shipped to Loki by
# nixos/modules/alloy.nix like any other log.
#
# Loki rather than Prometheus, deliberately. This is identity data with churn:
# IPv6 privacy addresses rotate constantly, so a neighbor gauge keyed by
# address and MAC would have unbounded cardinality, and the question these
# answer is always "what was true at 03:00" rather than "how many". The
# nftables accounting sets stay in Prometheus for the opposite reason: they
# are counters over a small, router-managed set.
#
# Before this, none of it was visible. node_exporter publishes
# node_arp_entries, which is a count per interface and nothing else, exports
# no netmask at all, and has no neighbor metric; the only IP-to-MAC pairs
# recoverable from telemetry came from parsing the MAC= field of nftables
# drop lines, which is a biased sample of hosts that tripped a rule.
{
  config,
  pkgs,
  ...
}:

let
  ip = "${pkgs.iproute2}/bin/ip";
  jq = "${pkgs.jq}/bin/jq";
  networkctl = "${config.systemd.package}/bin/networkctl";

  # Syslog identifier for these lines. It needs no relabeling in alloy.nix:
  # the lines go out on the unit's own stdout, which journald attributes to
  # the unit when the stream is opened, so they arrive labeled
  # unit="network-snapshot.service". The identifier just names them in
  # journalctl.
  identifier = "netsnap";
in
{
  systemd = {
    timers.network-snapshot = {
      description = "Sample router network state for Loki";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "2m";
        OnUnitActiveSec = "5m";
      };
    };

    services.network-snapshot = {
      description = "Router network state snapshot";
      serviceConfig = {
        Type = "oneshot";
        SyslogIdentifier = identifier;
      };

      # Written to stdout rather than through logger, for two reasons that
      # each lost data on the first deploy. logger splits anything over 1 KiB
      # into separate messages, so the neighbor and lease dumps arrived as
      # fragments of JSON; and a logger process exits before journald can
      # read its cgroup, so the small kinds arrived with no unit at all, the
      # same race the deploy provenance lines suffer. The stdout stream has
      # neither problem: its only limit is journald's LineMax, which the
      # sizing below is about.
      script = ''
        # One line per kind, prefixed so LogQL can select a kind with a line
        # filter before parsing any JSON. Reading the snapshot from stdin
        # keeps each producer a plain pipeline; a kind which produces nothing
        # (no leases yet, no default route, a command that failed) is skipped
        # rather than logged empty.
        snap() {
          out="$(cat)"

          if [ -z "$out" ] || [ "$out" = "[]" ]; then
            return 0
          fi

          printf 'kind=%s %s\n' "$1" "$out"
        }

        # Both of the dumps below are narrowed to the fields worth keeping,
        # for two reasons. A snapshot is one journal line and journald
        # truncates at LineMax, 48K by default; the router's neighbor table
        # across six VLANs, counting rotating IPv6 privacy addresses, is the
        # one dump big enough to get near that. And the fields dropped are
        # mostly lifetimes, which tick down on every sample: keeping them
        # would make consecutive snapshots differ even when nothing about
        # the network changed, which is the opposite of what these are for.

        # The neighbor tables: the point of the exercise. Both families, every
        # interface, with the state (REACHABLE, STALE, FAILED) that says how
        # much to trust each entry.
        ${ip} -json neigh show |
          ${jq} -c '[.[] | {dst, dev, lladdr, state}]' |
          snap neigh

        # Addresses carry the prefix length, which is what makes the subnet
        # layout readable; nothing in the metrics stack exports a netmask.
        ${ip} -json addr show |
          ${jq} -c '[.[] | {ifname, addrs: [.addr_info[] | {family, local, prefixlen, scope}]}]' |
          snap addr

        # Routes are deliberately narrow. Connected routes describe the
        # subnets, and the default routes say which uplink each family is
        # using, which is the question that prompted this. Everything bird
        # installs is excluded: dn42 imports up to 9000 prefixes per family
        # (see the import limit in dn42.nix), and dumping that every five
        # minutes would dwarf the rest of the homelab's logs to say something
        # the BIRD metrics already say better.
        ${ip} -json -4 route show proto kernel | snap route4
        ${ip} -json -6 route show proto kernel | snap route6
        ${ip} -json -4 route show default | snap default4
        ${ip} -json -6 route show default | snap default6

        # DHCP leases. networkd's built-in server logs nothing at all about
        # the leases it hands out, so the dynamic pool - which is most of the
        # IoT VLAN - has no history anywhere: there is no way to answer which
        # device held an address at a given time after the fact. The static
        # leases come from the inventory and are already known; the bound
        # ones are the new information.
        #
        # Read through networkctl rather than the lease files under
        # /run/systemd/netif/dhcp-server-lease/, which are a runtime
        # implementation detail: the JSON is the supported interface, and it
        # reports live server state rather than whatever was last persisted.
        # The filter is by presence of the DHCPServer object rather than by
        # its shape, so it keeps working if systemd renames a field inside.
        ${networkctl} --json=short status 2>/dev/null |
          ${jq} -c '[.Interfaces[] | select(.DHCPServer) | {Name, DHCPServer}]' |
          snap leases
      '';
    };
  };
}
