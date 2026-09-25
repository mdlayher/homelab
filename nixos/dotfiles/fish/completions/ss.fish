# Completions for ss from iproute2: the options and the state filter.

complete -c ss -s t -l tcp -d TCP
complete -c ss -s u -l udp -d UDP
complete -c ss -s w -l raw -d raw
complete -c ss -s x -l unix -d 'unix sockets'
complete -c ss -s l -l listening -d 'listening sockets'
complete -c ss -s a -l all -d 'listening and connected'
complete -c ss -s n -l numeric -d 'no name resolution'
complete -c ss -s p -l processes -d 'owning processes'
complete -c ss -s e -l extended -d 'uid, inode, cookie'
complete -c ss -s i -l info -d 'TCP internals'
complete -c ss -s m -l memory -d 'socket memory'
complete -c ss -s o -l options -d timers
complete -c ss -s s -l summary -d 'totals only'
complete -c ss -s H -l no-header
complete -c ss -s O -l oneline -d 'one line per socket'
complete -c ss -s K -l kill -d 'close matching sockets'
complete -c ss -s 4 -l ipv4
complete -c ss -s 6 -l ipv6
complete -c ss -s N -l net -x -a '(ip netns list 2>/dev/null | string replace -r " .*" "")' -d 'network namespace'
complete -c ss -s f -l family -x -a 'inet inet6 link unix netlink vsock xdp'
complete -c ss -s A -l query -x -a 'all inet tcp udp raw unix packet netlink'
complete -c ss -l bpf -d 'socket filter as BPF'
complete -c ss -f -a state -d 'filter by state'
complete -c ss -f -n '__fish_seen_subcommand_from state' -a 'established syn-sent syn-recv fin-wait-1 fin-wait-2 time-wait closed close-wait last-ack listening closing connected synchronized bucket big all'
complete -c ss -f -a 'dst src dport sport' -d 'filter expression'
