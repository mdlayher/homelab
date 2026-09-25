# Completions for vtysh. vtysh cannot list its command tree outside a
# session, so -c offers the show commands used for IS-IS and BFD on the
# circuits; anything else is typed as usual.

function __vtysh_commands
    printf '%s\n' \
        'show isis neighbor'\t'adjacencies' \
        'show isis neighbor detail'\t'adjacencies with timers' \
        'show isis interface'\t'circuits' \
        'show isis interface detail'\t'circuits with counters' \
        'show isis database'\t'LSPs' \
        'show isis database detail'\t'LSP contents' \
        'show isis route'\t'SPF results' \
        'show isis topology'\t'SPF tree' \
        'show isis hostname'\t'dynamic hostnames' \
        'show isis summary'\t'instance state' \
        'show bfd peers'\t'BFD sessions' \
        'show bfd peers brief'\t'BFD sessions, one line each' \
        'show bfd peers counters'\t'BFD packet counters' \
        'show ip route'\t'IPv4 RIB' \
        'show ipv6 route'\t'IPv6 RIB' \
        'show ip route isis'\t'IPv4 routes from IS-IS' \
        'show ipv6 route isis'\t'IPv6 routes from IS-IS' \
        'show interface brief'\t'zebra interfaces' \
        'show running-config'\t'running configuration' \
        'show daemons'\t'connected daemons' \
        'show version'\t'FRR version'
end

complete -c vtysh -f
complete -c vtysh -s c -l command -x -a '(__vtysh_commands)' -d 'run a command'
complete -c vtysh -s d -l daemon -x -a 'zebra isisd bfdd staticd mgmtd watchfrr' -d 'connect to one daemon'
complete -c vtysh -s b -l boot -d 'apply the integrated config'
complete -c vtysh -s f -l inputfile -r -F -d 'run commands from a file'
complete -c vtysh -s E -l echo -d 'echo commands'
complete -c vtysh -s C -l dryrun -d 'check config file syntax'
complete -c vtysh -s u -l user -d 'user mode only'
complete -c vtysh -s w -l writeconfig -d 'write the integrated config'
complete -c vtysh -s h -l help
complete -c vtysh -s v -l version
