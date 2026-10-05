# The LG TVs' configuration: every file this repository manages on a TV,
# built as a tree with a manifest for lgtv/deploy to apply. The TVs run
# webOS with Glasshouse rather than NixOS, so the files are rendered here
# and copied into place over SSH.
{
  lib,
  pkgs,
  sshKeys,
  # Each TV's fully qualified name, from the inventory.
  fqdn,
}:

let
  files = name: [
    # The admin's FIDO2 keys alone, so every login, a deploy from the
    # development container included, needs a physical YubiKey touch.
    # dropbear has no Match blocks to narrow a key to some sources.
    {
      path = "/home/root/.ssh/authorized_keys";
      mode = "600";
      source = pkgs.writeText "authorized_keys" (lib.concatLines sshKeys.fido);
    }
  ];

  tree =
    name:
    pkgs.runCommand "lgtv-${name}" { } (
      ''
        mkdir -p $out/tree
        install -m 0755 ${./apply.sh} $out/apply.sh
        echo ${fqdn.${name}} > $out/fqdn
      ''
      + lib.concatMapStrings (f: ''
        install -D -m ${f.mode} ${f.source} $out/tree${f.path}
        echo "${f.mode} ${f.path}" >> $out/manifest
      '') (files name)
    );
in
pkgs.linkFarm "lgtv-config" (
  map (name: {
    inherit name;
    path = tree name;
  }) (lib.attrNames fqdn)
)
