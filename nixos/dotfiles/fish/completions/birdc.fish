# Completions for birdc: the commands used day to day, from the CF_CLI
# declarations in bird's source. Protocol and table names come from the
# running daemon and complete nothing where its socket is unreachable.
# A filter expression still needs quoting: fish expands ~ and [ ] itself.

function __birdc_words
    string match -rv '^-' -- (commandline -opc)[2..]
end

# True when the words typed so far are exactly the arguments.
function __birdc_at
    set -l words (__birdc_words)
    test "$words" = "$argv"
end

# True when the words typed so far begin with the arguments.
function __birdc_under
    set -l words (__birdc_words)
    set -l n (count $argv)
    test (count $words) -ge $n; and test "$words[1..$n]" = "$argv"
end

# True when the last word typed is one of the arguments.
function __birdc_last
    set -l words (__birdc_words)
    test (count $words) -gt 0; and contains -- $words[-1] $argv
end

function __birdc_protocols
    birdc show protocols 2>/dev/null | string match -rv '^(BIRD |Name )' | string replace -r '^(\S+)\s+(\S+).*' '$1\t$2'
end

function __birdc_tables
    birdc show symbols table 2>/dev/null | string match -rv '^BIRD ' | string replace -r '^(\S+).*' '$1'
end

complete -c birdc -f
complete -c birdc -s s -r -F -d 'control socket'
complete -c birdc -s r -d 'restricted to read-only commands'
complete -c birdc -s v -d 'raw reply codes'

complete -c birdc -n __birdc_at -a show -d 'show state'
complete -c birdc -n __birdc_at -a configure -d 'reload configuration'
complete -c birdc -n __birdc_at -a enable -d 'enable protocol'
complete -c birdc -n __birdc_at -a disable -d 'disable protocol'
complete -c birdc -n __birdc_at -a restart -d 'restart protocol'
complete -c birdc -n __birdc_at -a reload -d 'reload protocol routes'
complete -c birdc -n __birdc_at -a debug -d 'protocol debugging'
complete -c birdc -n __birdc_at -a eval -d 'evaluate an expression'

complete -c birdc -n '__birdc_at show' -a status -d 'router status'
complete -c birdc -n '__birdc_at show' -a memory -d 'memory usage'
complete -c birdc -n '__birdc_at show' -a protocols -d 'routing protocols'
complete -c birdc -n '__birdc_at show' -a interfaces -d 'network interfaces'
complete -c birdc -n '__birdc_at show' -a route -d 'routing table'
complete -c birdc -n '__birdc_at show' -a symbols -d 'symbolic names'
complete -c birdc -n '__birdc_at show' -a bfd -d 'BFD sessions'
complete -c birdc -n '__birdc_at show' -a static -d 'static protocol'

complete -c birdc -n '__birdc_at show protocols' -a all -d 'with details'
complete -c birdc -n '__birdc_under show protocols' -a '(__birdc_protocols)'
complete -c birdc -n '__birdc_at show interfaces' -a summary
complete -c birdc -n '__birdc_at show bfd' -a sessions
complete -c birdc -n '__birdc_at show symbols' -a 'table filter function protocol template'

complete -c birdc -n '__birdc_under show route; and not __birdc_last protocol export preexport noexport table' -a 'for in table filter where all primary filtered export preexport noexport protocol stats count'
complete -c birdc -n '__birdc_under show route; and __birdc_last protocol export preexport noexport' -a '(__birdc_protocols)'
complete -c birdc -n '__birdc_under show route; and __birdc_last table' -a '(__birdc_tables)'

complete -c birdc -n '__birdc_at configure' -a check -d 'parse and validate only'
complete -c birdc -n '__birdc_at configure' -a soft -d 'ignore filter changes'
complete -c birdc -n '__birdc_at configure' -a status -d 'configuration status'
complete -c birdc -n '__birdc_at configure' -a confirm -d 'cancel the undo timeout'
complete -c birdc -n '__birdc_at configure' -a undo -d 'revert the last change'
complete -c birdc -n '__birdc_at configure' -a timeout -d 'undo unless confirmed'

complete -c birdc -n '__birdc_at reload' -a 'in out' -d 'one direction only'
complete -c birdc -n '__birdc_at enable; or __birdc_at disable; or __birdc_at restart; or __birdc_at reload; or __birdc_at reload in; or __birdc_at reload out; or __birdc_at debug' -a '(__birdc_protocols)'
complete -c birdc -n '__birdc_at enable; or __birdc_at disable; or __birdc_at restart; or __birdc_at reload; or __birdc_at reload in; or __birdc_at reload out' -a all -d 'every protocol'
