# Completions for nft: options, commands and object types. Table names
# come from the kernel and complete only when the shell may list them.

function __nft_words
    string match -rv '^-' -- (commandline -opc)[2..]
end

function __nft_at
    set -l words (__nft_words)
    test "$words" = "$argv"
end

# True after `<command> <object>`, where a family or table name is next.
function __nft_family_next
    set -l words (__nft_words)
    test (count $words) -eq 2; and contains -- $words[2] table chain set map counter flowtable
end

function __nft_table_next
    set -l words (__nft_words)
    test (count $words) -eq 3; and contains -- $words[3] inet ip ip6 arp bridge netdev
end

function __nft_tables
    set -l family (__nft_words)[3]
    nft list tables $family 2>/dev/null | string replace -rf '^table \S+ (\S+)$' '$1'
end

complete -c nft -f
complete -c nft -s a -l handle -d 'show rule handles'
complete -c nft -s n -l numeric -d 'no name resolution'
complete -c nft -s s -l stateless -d 'omit counter and quota values'
complete -c nft -s t -l terse -d 'omit set elements'
complete -c nft -s j -l json -d 'JSON output'
complete -c nft -s c -l check -d 'check without applying'
complete -c nft -s e -l echo -d 'echo what was added'
complete -c nft -s f -l file -r -F -d 'read commands from a file'

complete -c nft -n __nft_at -a list -d 'show objects'
complete -c nft -n __nft_at -a reset -d 'zero counters and quotas'
complete -c nft -n __nft_at -a monitor -d 'follow ruleset events'
complete -c nft -n __nft_at -a flush
complete -c nft -n __nft_at -a add
complete -c nft -n __nft_at -a insert
complete -c nft -n __nft_at -a replace
complete -c nft -n __nft_at -a delete
complete -c nft -n __nft_at -a get -d 'look up set elements'

complete -c nft -n '__nft_at list' -a 'ruleset tables table chains chain sets set maps map counters counter flowtables'
complete -c nft -n '__nft_at reset' -a 'counters counter rules quotas'
complete -c nft -n '__nft_at flush' -a 'ruleset table chain set map'
complete -c nft -n '__nft_at add; or __nft_at insert; or __nft_at replace; or __nft_at delete' -a 'table chain rule set map element counter'
complete -c nft -n '__nft_at get' -a element
complete -c nft -n '__nft_at monitor' -a 'new destroy trace'
complete -c nft -n __nft_family_next -a 'inet ip ip6 arp bridge netdev'
complete -c nft -n __nft_table_next -a '(__nft_tables)'
