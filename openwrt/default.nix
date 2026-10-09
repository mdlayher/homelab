# The OpenWrt machines' configuration: the uci settings and files this
# repository manages on each jump role holder, built for openwrt/deploy to
# apply. The machines run OpenWrt rather than NixOS, so the settings are
# rendered here from the same data the machines read and applied over SSH.
{
  lib,
  pkgs,
  inventory,
  sshKeys,
}:

let
  syslog = import ./syslog.nix;

  # dropbear's port for openwrt/deploy, over the tailnet. tailscaled's own
  # SSH server answers port 22 there, for personal devices only.
  sshPort = 2022;

  # Each managed uci setting, in order: a section before its options. A
  # section names its type, an option its value, and a list its values,
  # replacing whatever list the machine holds.
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
  ];

  renderSetting =
    s:
    if s ? section then
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
  ];

  host =
    name:
    pkgs.runCommand "openwrt-${name}" { } (
      ''
        mkdir -p $out/tree
        install -m 0755 ${./apply.sh} $out/apply.sh
        echo ${lib.escapeShellArg (lib.concatLines (map renderSetting (settings name)))} > $out/settings
        echo ${toString sshPort} > $out/port
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
