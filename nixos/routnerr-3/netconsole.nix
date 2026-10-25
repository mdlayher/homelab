# Kernel netconsole to the machine holding the loki service: each kernel
# log line as a UDP datagram to its raw listener (nixos/servnerr-4/loki.nix),
# the only record a panic here leaves anywhere else. The target is written
# through configfs once the management link is up; a kernel command line
# target would name the link before udev has renamed it.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  inventory = config.homelab.inventory;
  # The loki service's primary holder, on the management LAN.
  loki = inventory.hosts.${lib.head inventory.roles.${inventory.services.loki}};
  mgmt0 = inventory.interfaces.mgmt0;
  target = "/sys/kernel/config/netconsole/loki";
in
{
  # The holder's address and hardware address are inventory secrets,
  # rendered at activation.
  sops.templates."netconsole.env".content = ''
    REMOTE_IP=${loki.ipv4}
    REMOTE_MAC=${loki.mac}
  '';

  systemd.services.netconsole = {
    description = "Kernel netconsole to the loki host";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    path = [
      pkgs.kmod
      pkgs.util-linux
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      EnvironmentFile = config.sops.templates."netconsole.env".path;
    };
    # A target's settings can only be written while it is disabled, and
    # the kernel refuses to set a target to the state it already has. Like
    # any console, the target receives the messages below the console log
    # level (boot.consoleLogLevel): errors and worse, a panic among them.
    # Extended, each line carries its level, sequence number and timestamp.
    script = ''
      modprobe configfs
      mountpoint -q /sys/kernel/config || mount -t configfs none /sys/kernel/config
      modprobe netconsole
      mkdir -p ${target}
      if [ "$(cat ${target}/enabled)" = 1 ]; then
        echo 0 > ${target}/enabled
      fi
      echo ${mgmt0.name} > ${target}/dev_name
      echo ${mgmt0.ipv4} > ${target}/local_ip
      echo "$REMOTE_IP" > ${target}/remote_ip
      echo "$REMOTE_MAC" > ${target}/remote_mac
      echo 6666 > ${target}/remote_port
      echo 1 > ${target}/extended
      echo 1 > ${target}/enabled
    '';
    preStop = ''
      echo 0 > ${target}/enabled
      rmdir ${target}
    '';
  };
}
