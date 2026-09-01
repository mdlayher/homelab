# Network inventory: the public structure of subnets and hosts.
#
# Addresses, prefixes, and MACs are secrets in ./secrets.yaml (sops) and are
# rendered into configuration at activation time by nixos/modules/inventory.nix.
# This file only declares what exists and how each host's IPv6 addresses are
# formed:
#
# - "eui64":        the IID is derived from the MAC (switches, APs, IoT).
#                   Compute it with lib.nix, see nixos/README.md.
# - "token":        the host sets a fixed IID (networkd Token=static:::N).
# - "prefixstable": RFC 7217 stable privacy addresses; the observed IIDs are
#                   recorded per prefix in secrets.yaml.
# - null/omitted:   no IPv6 address is known; DNS gets an A record only.
{
  # Internal DNS domain for trusted LANs.
  domain = "lan.servnerr.com";

  # Tailnet MagicDNS suffix, under which machines and Tailscale Services
  # (see nixos/modules/tailscale-serve.nix) get their names.
  tailnetDomain = "taild07ab.ts.net";

  # Tailnet addresses referenced in configuration. Tailscale assigns them
  # when a node joins and they are stable for the node's lifetime; a node
  # replacement must be reflected here. sshd on the machines matches the
  # development container's source addresses to require the admin's FIDO2
  # key; see nixos/modules/common.nix.
  tailnetHosts.linuxdev = {
    ipv4 = "100.81.251.109";
    ipv6 = "fd7a:115c:a1e0::212e:fb6e";
  };

  # Stable role names for machines whose hostnames carry a generation number.
  # Configuration on other machines references roles rather than hostnames,
  # so replacing hardware only touches this file, the new machine's own
  # directory, and flake.nix.
  #
  # Each role lists its holders in precedence order: the first entry is the
  # primary, and during a generation swap the new machine is appended, so
  # consumers which fan out over every holder (such as Prometheus) cover
  # both machines until the old one is removed.
  roles = {
    router = [ "routnerr-3" ];
    server = [ "servnerr-4" ];
    monitor = [ "monitnerr-1" ];
  };

  # Subnets by router interface name. VLAN 0 is the untagged management LAN.
  subnets = {
    # Physical management LAN: servers and network infrastructure.
    mgmt0 = {
      vlan = 0;
      trusted = true;
      hosts = {
        ap-basement.ipv6 = "eui64";
        ap-livingroom.ipv6 = "eui64";
        hass.ipv6 = "prefixstable";
        monitnerr-1.ipv6 = "eui64";
        nerr-4.ipv6 = "prefixstable";
        pdu01.ipv6 = "eui64";
        servnerr-4.ipv6 = "token";
        switch-core.ipv6 = "eui64";
        switch-livingroom.ipv6 = "eui64";
        switch-office.ipv6 = "eui64";
        ups01.ipv6 = "eui64";
      };
    };

    # Home VLAN.
    lan0 = {
      vlan = 10;
      trusted = true;
      hosts = {
        matt-4.ipv6 = "eui64";
        psframework.ipv6 = "eui64";
        theatnerr-2.ipv6 = "eui64";
      };
    };

    # Guest VLAN: internet only.
    guest0 = {
      vlan = 9;
      trusted = false;
    };

    # Development VLAN: internet only, for containers on the server running
    # agents and networking experiments.
    dev0 = {
      vlan = 20;
      trusted = false;
      hosts = {
        "frrdev.dev".ipv6 = "token";
        "linuxdev.dev".ipv6 = "token";
      };
    };

    # IoT VLAN: internet only, mDNS reflected from trusted LANs.
    iot0 = {
      vlan = 66;
      trusted = false;
      hosts = {
        keylight.ipv6 = "eui64";
        "living-room-hue-hub.iot".ipv6 = "eui64";
        "living-room-myq-hub.iot".ipv6 = "eui64";
        "office-printer.iot".ipv6 = "eui64";
        "prusa-core-one.iot".ipv6 = "eui64";
      };
    };
  };
}
