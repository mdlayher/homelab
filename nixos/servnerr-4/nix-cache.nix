# The binary cache described in nixos/modules/nix-cache.nix. harmonia serves
# this machine's store and signs each path as it serves it, so the plain
# HTTP it speaks needs no TLS for integrity.
{
  config,
  inputs,
  lib,
  ...
}:

let
  # The machines that substitute from the cache.
  clients = lib.attrNames (
    lib.filterAttrs (_: c: c.config.homelab.nixCache.client) inputs.self.nixosConfigurations
  );

  # The flake the nightly upgrade applies, so this builds what the clients
  # will ask for.
  flake = config.system.autoUpgrade.flake;
in
{
  sops.secrets."nix/cache_key" = { };

  services.harmonia.cache = {
    enable = true;
    signKeyPaths = [ config.sops.secrets."nix/cache_key".path ];
    settings.bind = "[::]:${toString config.homelab.nixCache.port}";
  };

  # Builds each client's system from the published flake before the
  # clients' nightly upgrade at 04:40, after the 04:00 garbage collection.
  # The out-links are GC roots, so the newest build of each survives until
  # the next one replaces it.
  systemd.services.nix-cache-prebuild = {
    description = "Build the binary cache clients' systems";
    startAt = "04:10";
    path = [ config.nix.package ];
    environment.HOME = "/var/cache/nix-cache-prebuild";
    serviceConfig = {
      Type = "oneshot";
      DynamicUser = true;
      StateDirectory = "nix-cache-prebuild";
      CacheDirectory = "nix-cache-prebuild";
    };
    # One client's failure leaves the others to build, and fails the unit.
    script = ''
      rc=0
    ''
    + lib.concatMapStrings (host: ''
      nix build --refresh --out-link "$STATE_DIRECTORY/${host}" \
        '${flake}#nixosConfigurations.${host}.config.system.build.toplevel' || rc=1
    '') clients
    + ''
      exit $rc
    '';
  };
}
