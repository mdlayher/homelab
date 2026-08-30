# dotfiles

Shell configuration installed system-wide on every machine and development
container (see `nixos/modules/common.nix`), templated from `~/.config/fish` on
my desktop:
`fish/conf.d/*` and `fish/functions/*` are packaged into fish's vendor
directories (`share/fish/vendor_conf.d`, `vendor_functions.d`), which fish
searches from the system profile for every user. Machine-specific pieces (atuin init, `$EDITOR`, `~/bin` in
`PATH`) are expressed as NixOS options instead of files.
