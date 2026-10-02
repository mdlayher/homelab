# The server's binary cache of this homelab's own builds, served over the
# tailnet as svc:nix-cache and signed as it is served (see
# nixos/servnerr-4/nix-cache.nix). A machine setting client substitutes from
# it; the server builds those machines' systems ahead of their nightly
# upgrade, and nixos/deploy builds them there before a deploy.
{ config, lib, ... }:

let
  cfg = config.homelab.nixCache;
in
{
  options.homelab.nixCache = {
    client = lib.mkEnableOption "substituting from the server's binary cache";

    url = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = "https://nix-cache.${config.homelab.inventory.tailnetDomain}";
      description = "The cache's address on the tailnet.";
    };

    publicKey = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = "nix-cache.taild07ab.ts.net-1:+mqw7ahA2hN+tv65B3PMui2ogd1oc/a5VNTC/nTyvhE=";
      description = "The public half of the key the cache signs with.";
    };
  };

  config = lib.mkIf cfg.client {
    nix.settings = {
      substituters = [ cfg.url ];
      trusted-public-keys = [ cfg.publicKey ];
    };
  };
}
