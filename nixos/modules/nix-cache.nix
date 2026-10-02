# The server's binary cache of this homelab's own builds, signed as it is
# served (see nixos/servnerr-4/nix-cache.nix). A machine setting client
# substitutes from nix-cache.svc, the server role's primary holder, over the
# LAN or, from another site, the interconnect, the way Alloy reaches Loki;
# the router admits it in iclServices. The server builds the clients'
# systems ahead of their nightly upgrade, and nixos/deploy builds them there
# before a deploy.
{
  config,
  inputs,
  lib,
  ...
}:

let
  cfg = config.homelab.nixCache;
  inventory = config.homelab.inventory;

  # The port from the primary holder's own configuration.
  server = lib.head inventory.roles.${inventory.services.nix-cache};
  port = inputs.self.nixosConfigurations.${server}.config.homelab.nixCache.port;
in
{
  options.homelab.nixCache = {
    client = lib.mkEnableOption "substituting from the server's binary cache";

    port = lib.mkOption {
      type = lib.types.port;
      readOnly = true;
      default = 5000;
      description = "The port the cache listens on at its role holders.";
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
      substituters = [ "http://nix-cache.svc.${inventory.zone}:${toString port}" ];
      trusted-public-keys = [ cfg.publicKey ];
    };
  };
}
