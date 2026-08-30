# dotfiles

Configuration files templated from my desktop and installed system-wide on
every machine and development container by `nixos/modules/common.nix`, so all
users get the same shell and tool defaults. Per-user configuration in a home
directory still overrides. Machine-specific pieces are expressed as NixOS
options rather than files.
