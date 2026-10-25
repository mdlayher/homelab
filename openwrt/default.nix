# The OpenWrt machines' configuration: the uci settings and files this
# repository manages on each jump role holder, built for openwrt/deploy to
# apply. The machines run OpenWrt rather than NixOS, so the settings are
# rendered here from the same data the machines read and applied over SSH.
{
  lib,
  pkgs,
  inventory,
  siteInventory,
  sshKeys,
}:

let
  syslog = import ./syslog.nix;

  # dropbear's port for openwrt/deploy, over the tailnet. Port 22 is left
  # to tailscaled's SSH server, which is off (see README.md).
  sshPort = (import ./dropbear.nix).port;

  # The segment the server scrapes the machines from.
  mgmt = siteInventory.interfaces.mgmt0;
  nodeExporterPort = 9100;

  # Loki by its service name, which follows the role serving it. It
  # answers with the host's management LAN address.
  loki = "loki.svc.${inventory.zone}";

  # Packages the machines need beyond the OpenWrt image, for the managed
  # settings, the LTE modem and working on them by hand, installed by hand
  # (see README.md); apply.sh refuses to change anything while one is
  # missing.
  packages = [
    "kmod-netconsole"
    "kmod-usb-net-cdc-mbim"
    "kmod-usb-serial-qualcomm"
    "mbim-utils"
    "modemmanager"
    "picocom"
    "prometheus-node-exporter-lua"
    "prometheus-node-exporter-lua-modemmanager"
    "prometheus-node-exporter-lua-netstat"
    "prometheus-node-exporter-lua-openwrt"
    "tailscale"
  ];

  # Each managed uci setting, in order: a section before its options. A
  # section names its type, an option its value, and a list its values,
  # replacing whatever list the machine holds. An unset option is deleted,
  # as is every section of an absent type whose option holds the value in
  # where.
  settings = name: [
    {
      option = "system.@system[0].hostname";
      value = name;
    }
    # logd sends each line to the server's RFC 3164 listener as written;
    # see nixos/servnerr-4/loki.nix.
    {
      option = "system.@system[0].log_ip";
      value = "loki.svc.${inventory.zone}";
    }
    {
      option = "system.@system[0].log_port";
      value = toString syslog.port;
    }
    {
      option = "system.@system[0].log_proto";
      value = "udp";
    }
    # dnsmasq discards upstream answers holding private addresses, which is
    # every internal name.
    {
      list = "dhcp.@dnsmasq[0].rebind_domain";
      values = [ inventory.zone ];
    }
    # The factory's local domain, answered by dnsmasq alone.
    {
      unset = "dhcp.@dnsmasq[0].local";
    }
    {
      unset = "dhcp.@dnsmasq[0].domain";
    }
    {
      section = "firewall.tailscale";
      type = "zone";
    }
    {
      option = "firewall.tailscale.name";
      value = "tailscale";
    }
    {
      option = "firewall.tailscale.device";
      value = "tailscale0";
    }
    {
      option = "firewall.tailscale.input";
      value = "ACCEPT";
    }
    {
      option = "firewall.tailscale.output";
      value = "ACCEPT";
    }
    {
      option = "firewall.tailscale.forward";
      value = "REJECT";
    }
    # The stock dropbear instance on port 22 takes keys alone, as every
    # SSH server here does.
    {
      option = "dropbear.main.PasswordAuth";
      value = "off";
    }
    {
      option = "dropbear.main.RootPasswordAuth";
      value = "off";
    }
    # The dropbear instance openwrt/deploy logs in to, keys only.
    {
      section = "dropbear.deploy";
      type = "dropbear";
    }
    {
      option = "dropbear.deploy.Port";
      value = toString sshPort;
    }
    {
      option = "dropbear.deploy.PasswordAuth";
      value = "off";
    }
    {
      option = "dropbear.deploy.RootPasswordAuth";
      value = "off";
    }
    # prometheus-node-exporter-lua, scraped by the server; see
    # nixos/servnerr-4/prometheus.nix. It listens on every interface, and
    # the firewall admits mgmt alone.
    {
      option = "prometheus-node-exporter-lua.main.listen_interface";
      value = "*";
    }
    {
      option = "prometheus-node-exporter-lua.main.listen_port";
      value = toString nodeExporterPort;
    }
    {
      section = "firewall.node_exporter";
      type = "rule";
    }
    {
      option = "firewall.node_exporter.name";
      value = "Allow-node-exporter";
    }
    {
      option = "firewall.node_exporter.src";
      value = "wan";
    }
    {
      option = "firewall.node_exporter.proto";
      value = "tcp";
    }
    {
      option = "firewall.node_exporter.dest_port";
      value = toString nodeExporterPort;
    }
    {
      list = "firewall.node_exporter.src_ip";
      values = [
        "${mgmt.ipv4Prefix}.0/24"
        "${mgmt.ulaPrefix}::/64"
      ];
    }
    {
      option = "firewall.node_exporter.target";
      value = "ACCEPT";
    }
    # The factory LAN: the bridge of the other ports at 192.168.1.1, its
    # DHCP server, firewall zone, forwarding and rules, the ULA prefix
    # generated at first boot for it, and the LED showing its activity.
    {
      absent = "network.interface";
      where = "device=br-lan";
    }
    {
      absent = "network.device";
      where = "name=br-lan";
    }
    {
      unset = "network.globals.ula_prefix";
    }
    {
      absent = "dhcp.dhcp";
      where = "interface=lan";
    }
    {
      absent = "firewall.zone";
      where = "name=lan";
    }
    {
      absent = "firewall.forwarding";
      where = "src=lan";
    }
    {
      absent = "firewall.rule";
      where = "dest=lan";
    }
    {
      absent = "system.led";
      where = "dev=br-lan";
    }
  ];

  renderSetting =
    s:
    if s ? absent then
      "absent ${s.absent} ${s.where}"
    else if s ? unset then
      "unset ${s.unset}"
    else if s ? section then
      "section ${s.section} ${s.type}"
    else if s ? list then
      "list ${s.list} ${lib.concatStringsSep " " s.values}"
    else
      "option ${s.option} ${s.value}";

  # Each managed file: its path on the machine, mode, contents, and what
  # applying a change to it takes (see apply.sh).
  files = [
    {
      # dropbear's keys for root, the admin's FIDO2 keys alone, so every
      # login needs a physical touch. OpenWrt builds dropbear without ECDSA,
      # so a key of that type is skipped.
      path = "/etc/dropbear/authorized_keys";
      mode = "600";
      action = "none";
      text = lib.concatLines sshKeys.fido;
    }
    {
      # Kernel netconsole to the loki host over the management LAN, which
      # carries what logd cannot ship, a panic among it. OpenWrt's module
      # has no configfs interface, so the target is a module parameter,
      # set again each time the management interface comes up: the kernel
      # builds the frames itself, so the host's hardware address comes
      # from the neighbor table once a ping has filled it. OpenWrt's
      # modprobe takes no parameters, so the load is insmod's. Like any
      # console it receives the messages below the console log level,
      # here the kernel's default.
      path = "/etc/hotplug.d/iface/30-netconsole";
      mode = "644";
      action = "netconsole";
      text = ''
        #!/bin/sh
        [ "$ACTION" = ifup ] && [ "$INTERFACE" = wan ] || exit 0
        addr=$(nslookup ${loki} 2>/dev/null | awk '$1 == "Address:" && $2 ~ /^[0-9.]+$/ { print $2; exit }')
        if [ -z "$addr" ]; then
          logger -t netconsole "cannot resolve ${loki}"
          exit 1
        fi
        ping -c 1 -W 5 "$addr" >/dev/null
        lladdr=$(ip neigh show to "$addr" dev "$DEVICE" | awk '{ for (i = 1; i < NF; i++) if ($i == "lladdr") print $(i + 1) }')
        rmmod netconsole 2>/dev/null
        insmod netconsole netconsole="@/$DEVICE,6666@$addr/$lladdr"
      '';
    }
  ];

  host =
    name:
    pkgs.runCommand "openwrt-${name}" { } (
      ''
        mkdir -p $out/tree
        install -m 0755 ${./apply.sh} $out/apply.sh
        echo ${lib.escapeShellArg (lib.concatLines (map renderSetting (settings name)))} > $out/settings
        echo ${toString sshPort} > $out/port
        echo ${lib.escapeShellArg (lib.concatLines packages)} > $out/packages
        touch $out/manifest
      ''
      + lib.concatMapStrings (f: ''
        install -D -m ${f.mode} ${pkgs.writeText "openwrt-file" f.text} $out/tree${f.path}
        echo "${f.mode} ${f.path} ${f.action}" >> $out/manifest
      '') files
    );

  hosts = inventory.roles.jump;
in
pkgs.linkFarm "openwrt-config" (
  map (name: {
    inherit name;
    path = host name;
  }) hosts
)
