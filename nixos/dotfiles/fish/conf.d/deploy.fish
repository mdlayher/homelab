# Completions for nixos/deploy, pikvm/deploy and windows/deploy, told apart
# by the directory of the script being invoked since all are named deploy:
# for nixos/deploy, machine names from its sibling machine directories, then
# the action; for windows/deploy, any of the machines in its hosts.nix. Lives
# in conf.d rather than a completions directory because fish only autoloads
# completion files for commands resolvable in PATH, and deploy is always
# invoked by path.

function __deploy_hosts
    set -l script (commandline -opc)[1]
    for conf in (dirname $script)/*/configuration.nix
        basename (dirname $conf)
    end
end

# The quoted names in the hosts list of windows/hosts.nix.
function __deploy_windows_hosts
    set -l script (commandline -opc)[1]
    sed -n '/hosts = \[/,/\];/p' (dirname $script)/hosts.nix | string match -rg '"([^"]+)"'
end

# Whether the deploy script being invoked lives in directory $argv[1] and
# the completion is for argument $argv[2].
function __deploy_arg
    set -l words (commandline -opc)
    test (basename (dirname $words[1])) = $argv[1]; and test (count $words) -eq $argv[2]
end

complete -c deploy -f

complete -c deploy -n '__deploy_arg nixos 1' -a '(__deploy_hosts)' -d machine
complete -c deploy -n '__deploy_arg nixos 1' -a '--all' -d 'edges, then server, then router'
complete -c deploy -n '__deploy_arg nixos 2' -a 'switch' -d 'activate and add boot entry (default)'
complete -c deploy -n '__deploy_arg nixos 2' -a 'test' -d 'activate without boot entry; reboot reverts'
complete -c deploy -n '__deploy_arg nixos 2' -a 'boot' -d 'boot entry only, no activation'
complete -c deploy -n '__deploy_arg nixos 2' -a 'dry-activate' -d 'show what would change'

complete -c deploy -n '__deploy_arg pikvm 1' -a '--check' -d 'show drift, change nothing'

complete -c deploy -n '__deploy_arg windows 1' -a '--check' -d 'show drift, change nothing'
complete -c deploy -n 'test (basename (dirname (commandline -opc)[1])) = windows' -a '(__deploy_windows_hosts)' -d machine
