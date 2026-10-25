# The port of the dropbear instance openwrt/deploy logs in to, set on each
# machine (./default.nix) and given to ssh by the development container's
# client configuration (nixos/servnerr-4/dev.nix).
{
  port = 2022;
}
