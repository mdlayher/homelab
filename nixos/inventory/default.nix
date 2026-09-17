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
  # The zone internal names live under. Each site answers <site>.<zone> and
  # each segment a <role>.<site>.<zone> beneath it, so a name says where a
  # host is. None of it is published: the public zone is Cloudflare's (see
  # terraform/cloudflare/mdlayher_net.tf), which answers NXDOMAIN for these,
  # and no certificate carries one. Nothing may serve the zone itself, only
  # labels beneath it, or public names stop resolving on the LAN.
  zone = "mdlayher.net";

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

  # A /56 of the ULA for interconnect carriers, one /127 per link. These
  # address the outside of each GRETAP and live inside its WireGuard tunnel,
  # so nothing routes to them; they exist because a GRETAP needs a local and
  # a remote address to be built on. Below labPrefix, above every real
  # subnet, for the same reason labPrefix is where it is.
  interconnectPrefix = "fd9e:1a04:f01d:fe00::/56";

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
      pdx = "0000.0000.0201";
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

  # The sites this network spans, each answering <name>.<zone>. A machine
  # names its own in homelab.site; devices are placed by the segment they
  # sit on.
  sites.azo = {
    # Retired, still answered. Names beneath these keep the shapes they have
    # today, unlabelled by segment, because they are hardcoded where this
    # file cannot see them: ssh configuration, known_hosts, and the home
    # automation box. Empty the list once those have moved.
    aliasDomains = [ "lan.servnerr.com" ];

    # Subnets by router interface name. VLAN 0 is the untagged management LAN.
    subnets = {
      # Physical management LAN: servers and network infrastructure.
      mgmt0 = {
        vlan = 0;
        trusted = true;
        # DNS namespace for hosts here, and the search domain this segment is
        # handed. A role rather than the interface name: two segments serving
        # the same role share a namespace, which is what mutual reachability
        # means, and renumbering the topology then renames nothing.
        role = "mgmt";
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
        role = "lan";
        hosts = {
          matt-4.ipv6 = "eui64";
          psframework.ipv6 = "eui64";
          theatnerr-2.ipv6 = "eui64";
        };
      };

      # Guest VLAN: internet only. No search domain is advertised here and no
      # host is named, so the role exists to classify the segment alone.
      guest0 = {
        vlan = 9;
        trusted = false;
        role = "guest";
      };

      # Development VLAN: internet only, for containers and microvms on the
      # server running agents and networking experiments.
      dev0 = {
        vlan = 20;
        trusted = false;
        role = "dev";
        hosts = {
          frrdev.ipv6 = "token";
          homadev.ipv6 = "token";
          linuxdev.ipv6 = "token";
          quicdev.ipv6 = "token";
        };
      };

      # IoT VLAN: internet only, mDNS reflected from trusted LANs.
      iot0 = {
        vlan = 66;
        trusted = false;
        role = "iot";
        hosts = {
          keylight.ipv6 = "eui64";
          living-room-hue-hub.ipv6 = "eui64";
          living-room-myq-hub.ipv6 = "eui64";
          office-printer.ipv6 = "eui64";
          prusa-core-one.ipv6 = "eui64";
        };
      };
    };
  };

  # A single EC2 host terminating one interconnect circuit. No LAN, so no
  # subnets, and nothing answers beneath its domain yet.
  sites.pdx = { };
}
