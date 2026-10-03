# The binary cache described in nixos/modules/nix-cache.nix. harmonia serves
# this machine's store and signs each path as it serves it, so the plain
# HTTP it speaks needs no TLS for integrity.
{
  config,
  inputs,
  lib,
  pkgs,
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
  # harmonia signs every path in this store, and the clients install what
  # it signs as root. An untrusted user, the agents in linuxdev among
  # them, can add only paths named for their own contents or for a build
  # the daemon ran itself, so a client asking for a path gets what that
  # name promises. A trusted user could import any content under any name,
  # which would then be signed and trusted everywhere.
  assertions = [
    {
      assertion = config.nix.settings.trusted-users == [ "root" ];
      message = "nix-cache: the server signs its whole store, so trusted-users must stay [ \"root\" ].";
    }
  ];

  # Builds for clients of another architecture run here under emulation,
  # slowly but off the client.
  boot.binfmt.emulatedSystems = lib.unique (
    lib.filter (system: system != pkgs.stdenv.hostPlatform.system) (
      map (host: inputs.self.nixosConfigurations.${host}.pkgs.stdenv.hostPlatform.system) clients
    )
  );

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
