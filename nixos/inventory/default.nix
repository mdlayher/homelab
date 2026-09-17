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

  # The site ULA /48. Public by choice: https://ula.ungleich.ch/.
  ulaPrefix = "fd9e:1a04:f01d::/48";

  # The RFC 1918 space every site LAN is drawn from. Deliberately the whole
  # /16 rather than the subnets themselves, which are secrets: this is used
  # to tell our own traffic from dn42's on a link carrying both (see the
  # router's nftables.nix), and being broader costs nothing there. What it
  # must stay is disjoint from dn42's 172.20.0.0/14, so a future site keeps
  # to 192.168/16 or 10/8.
  privatePrefix = "192.168.0.0/16";

  # A /56 of the ULA set aside for lab use, never assigned to a real subnet.
  # Every site prefix in use sits in the 0th /56 -- the subnets below put
  # their VLAN id in the fourth hextet and all of those are under 100 -- so
  # the top /56 cannot collide with one. Plain data for the same reason
  # ulaPrefix is: it names a range, not an address.
  labPrefix = "fd9e:1a04:f01d:ff00::/56";

  # IS-IS identity. Assigned here because nothing derives it: a system ID
  # is not an address and must not be built from one, so it survives any
  # renumbering, and a file has to be the registry or it drifts.
  #
  # 49 is the AFI for private NSAP addressing, the CLNS equivalent of
  # RFC 1918. The area is 49.00SS and the system ID 0000.0000.SSRR, where
  # SS is the site byte of the addressing scheme (see the router's
  # dn42.nix) and RR the router within that site.
  #
  # One flat level-2 backbone today, so every router shares an area and
  # the value is mostly latent; per-site level-1 areas would each use
  # their own site's.
  isis = {
    area = "49.0001";
    systemIds = {
      routnerr-3 = "0000.0000.0101";
      frrdev = "0000.0000.01ff";
    };
  };

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

  # Stable service names, published in internal DNS as <service>.svc.<domain>
  # resolving to the primary holder of the named role. Devices which cannot
  # join the tailnet (appliances, add-on containers) may hardcode these names
  # to reach a service independent of the machine currently serving that
  # role: a generation swap moves the name when the role's holder list is
  # reordered, and hardcoded clients follow it at their next lookup.
  services = {
    loki = "server";
    prometheus = "server";
  };

  # Subnets by router interface name. VLAN 0 is the untagged management LAN.
  subnets = {
    # Physical management LAN: servers and network infrastructure.
    mgmt0 = {
      vlan = 0;
      trusted = true;
      hosts = {
        ap-basement = { };
        ap-livingroom = { };
        hass.ipv6 = "prefixstable";
        monitnerr-1.ipv6 = "eui64";
        nerr-4.ipv6 = "prefixstable";
        pdu01 = { };
        servnerr-4.ipv6 = "token";
        switch-core.ipv6 = "eui64";
        switch-livingroom.ipv6 = "eui64";
        ups01 = { };
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

    # Development VLAN: internet only, for containers and microvms on the
    # server running agents and networking experiments.
    dev0 = {
      vlan = 20;
      trusted = false;
      hosts = {
        "frrdev.dev".ipv6 = "token";
        "homadev.dev".ipv6 = "token";
        "linuxdev.dev".ipv6 = "token";
        "quicdev.dev".ipv6 = "token";
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
