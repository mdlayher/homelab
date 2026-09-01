# Completions for nixos/deploy: machine names from the sibling machine
# directories of the deploy script being invoked, then the action.

function __deploy_hosts
    set -l script (commandline -opc)[1]
    for conf in (dirname $script)/*/configuration.nix
        basename (dirname $conf)
    end
end

complete -c deploy -f
complete -c deploy -n 'test (count (commandline -opc)) -eq 1' -a '(__deploy_hosts)' -d machine
complete -c deploy -n 'test (count (commandline -opc)) -eq 2' -a 'switch' -d 'activate and add boot entry (default)'
complete -c deploy -n 'test (count (commandline -opc)) -eq 2' -a 'test' -d 'activate without boot entry; reboot reverts'
complete -c deploy -n 'test (count (commandline -opc)) -eq 2' -a 'boot' -d 'boot entry only, no activation'
complete -c deploy -n 'test (count (commandline -opc)) -eq 2' -a 'dry-activate' -d 'show what would change'
