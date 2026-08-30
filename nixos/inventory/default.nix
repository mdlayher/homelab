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

  # Subnets by router interface name. VLAN 0 is the untagged management LAN.
  subnets = {
    # Physical management LAN: servers and network infrastructure.
    mgmt0 = {
      vlan = 0;
      trusted = true;
      hosts = {
        ap-basement.ipv6 = "eui64";
        ap-livingroom.ipv6 = "eui64";
        hass.ipv6 = "eui64";
        monitnerr-1.ipv6 = "eui64";
        nerr-4.ipv6 = "eui64";
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
