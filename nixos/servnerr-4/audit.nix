# Kernel audit of the directories a Tailscale SSH session may forward unix
# sockets into, on this machine and in the development container, whose
# root filesystem is a directory here. Root binding a socket there, and a
# storm of renames, mark a session steering the root daemon into a
# privileged socket. journald collects the records, which reach Loki like
# every other journal line; loki.nix alerts on them.
{ lib, ... }:

let
  # The container's /run/user is a tmpfs of its own namespace, unreachable
  # from here, so it goes unwatched.
  dirs = [
    "/tmp"
    "/home"
    "/var/lib/nixos-containers/linuxdev/tmp"
    "/var/lib/nixos-containers/linuxdev/home"
  ];

  rule =
    dir: filters: key:
    "-a always,exit -F arch=b64 ${filters} -F dir=${dir} -k ${key}";
in
{
  security.audit = {
    enable = true;
    rules = lib.concatMap (dir: [
      (rule dir "-S bind -F uid=0" "tailscale-socket")
      (rule dir "-S rename,renameat,renameat2" "tailscale-socket-rename")
    ]) dirs;
  };

  services.journald.audit = true;
}
