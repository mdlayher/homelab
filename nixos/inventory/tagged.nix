# The names of the inventory hosts holding a tag, at every site, in name
# order. Builtins only, since lgtv/deploy and windows/deploy evaluate the
# files reading it with nix eval --file and no nixpkgs. Modules select
# hosts with the inventory module's tagged instead, which returns their
# records.
tag:
let
  inventory = import ./.;
  subnets = builtins.concatMap (s: builtins.attrValues (s.subnets or { })) (
    builtins.attrValues inventory.sites
  );
  hosts = builtins.foldl' (all: subnet: all // (subnet.hosts or { })) { } subnets;
in
builtins.filter (name: builtins.elem tag (hosts.${name}.tags or [ ])) (builtins.attrNames hosts)
