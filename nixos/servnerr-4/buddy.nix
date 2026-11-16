# The buddy backups: each machine in homelab.buddies (set in buddies.nix)
# pushes its backups here over SFTP, through the router's remote access
# tunnel (see the router's remote-access.nix), into a dataset of its own
# under primary/buddy (see storage.nix).
#
# Each account is chrooted to its dataset and offered SFTP alone. sshd
# demands a chroot directory owned by root and writable by no one else, so
# the dataset's mountpoint stays root's and the account writes into a
# subdirectory of it.
{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:

let
  inventory = config.homelab.inventory;
  buddies = config.homelab.buddies;

  # The writable subdirectory, as the chrooted account sees it.
  dir = "/backups";
  chroot = name: "/primary/buddy/${name}";

  # Each machine's address in the tunnel, which its key is pinned to.
  devices =
    inputs.self.nixosConfigurations.${lib.head inventory.roles.router}.config.homelab.remoteAccess.devices;
in
{
  imports = [ ./buddies.nix ];

  options.homelab.buddies = lib.mkOption {
    default = { };
    description = ''
      Machines trading backups with this server over SFTP, by account
      name. Each is a remote access device on the router, named
      buddy-<name>, reaching this server's SSH and reached by it on its
      own, and its account is chrooted to its dataset,
      primary/buddy/<name> (see storage.nix).
    '';
    type = lib.types.attrsOf (
      lib.types.submodule {
        options = {
          index = lib.mkOption {
            type = lib.types.ints.between 1 4095;
            description = "The machine's number among the buddies, which places its tunnel address at ::b001 and up; see the router's remote-access.nix.";
          };
          sshPort = lib.mkOption {
            type = lib.types.port;
            default = 22;
            description = "The port the machine's sshd listens on, which this server pushes to.";
          };
          wireguardKey = lib.mkOption {
            type = lib.types.str;
            description = "The machine's WireGuard public key.";
          };
          sshKey = lib.mkOption {
            type = lib.types.str;
            description = "The machine's SSH public key, pinned to its tunnel address.";
          };
        };
      }
    );
  };

  config.users = {
    users = lib.mapAttrs (name: buddy: {
      isSystemUser = true;
      group = name;
      home = "/var/empty";
      createHome = false;
      shell = "${pkgs.shadow}/bin/nologin";
      openssh.authorizedKeys.keys = [
        ''from="${devices."buddy-${name}".address}",restrict ${buddy.sshKey}''
      ];
    }) buddies;
    groups = lib.mapAttrs (_: _: { }) buddies;
  };

  config.systemd.tmpfiles.rules = lib.mapAttrsToList (
    name: _: "d ${chroot name}${dir} 0700 ${name} ${name} -"
  ) buddies;

  # The SFTP server logs each session's file operations to syslog, which it
  # opens after the chroot: the journal's socket is bound into each chroot
  # at /dev/log for it to find.
  config.fileSystems = lib.mapAttrs' (
    name: _:
    lib.nameValuePair "${chroot name}/dev/log" {
      device = "/run/systemd/journal/dev-log";
      fsType = "none";
      options = [
        "bind"
        "nofail"
      ];
    }
  ) buddies;

  config.services.openssh.extraConfig = lib.concatStrings (
    lib.mapAttrsToList (name: _: ''
      Match User ${name}
        ChrootDirectory ${chroot name}
        ForceCommand internal-sftp -l INFO -d ${dir}
        AuthenticationMethods publickey
        AllowTcpForwarding no
        AllowStreamLocalForwarding no
        AllowAgentForwarding no
        PermitTunnel no
        X11Forwarding no
        PermitTTY no
    '') buddies
  );
}
