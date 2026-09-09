{ config, ... }:

let
  inventory = config.homelab.inventory;

  # The host's address on the internal dn42 VLAN (see the bridge below),
  # making it a dn42 host like the container. dn42 registry space matching
  # the router's dn42.nix and the container's dev.nix: the next IPv4 after
  # the container's .83, with the same number as interface identifier (::10
  # is the container's here). Static, as the bridge takes no advertisements,
  # and dn42 space only, never a default. Our own /48 is routed explicitly:
  # mgmt0 learns it from the router's advertisements at metric 1024, and
  # dn42 traffic must take the VLAN.
  dn42 = {
    addr4 = "172.20.140.84/28";
    addr6 = "fde4:d0ad:ee0f:1::84/64";
    router4 = "172.20.140.82";
    router6 = "fde4:d0ad:ee0f:1::1";
    routes4 = [ "172.20.0.0/14" ];
    routes6 = [
      "fde4:d0ad:ee0f::/48"
      "fd00::/8"
    ];
    metric = 512;
  };
in
{
  # A machine with a dn42 interface trusts the dn42 CA; see dn42 above.
  imports = [ ../modules/dn42-ca.nix ];

  networking = {
    # Host name and ID.
    hostName = "servnerr-4";
    hostId = "ed66dcdd";

    # Use systemd-networkd for configuration. Forcibly disable legacy DHCP client.
    useNetworkd = true;
    useDHCP = false;

    # Local firewall: the tailnet rides its own ACLs, SSH and tailscale open
    # their own ports, and loopback is free, which covers Prometheus scraping
    # this machine's exporters and probing its services. The LAN may reach
    # only the ports below.
    firewall = {
      trustedInterfaces = [ "ts0" ];

      # The ports below open on every interface, the dn42 VLAN included
      # (see dn42 above). dn42 at large never reaches them: the router's
      # forward_dn42i chain (its nftables.nix) admits only ICMP and
      # established flows. The VLAN itself it never sees: the development
      # container is on-link there, so this drop guards against a neighbor
      # and backs the router. Nothing new inbound, like the router's WANs;
      # the host's own flows return as established, and neighbor discovery
      # is untracked. iptables backend: extraInputRules is a no-op and
      # extraCommands run after the accepts, so insert at the head. The
      # bridge holds the address, not its VLAN port.
      extraCommands = ''
        ip46tables -I nixos-fw 1 -i br-dn42i-dev0 -m conntrack --ctstate NEW,INVALID -j DROP
      '';
      allowedTCPPorts = [
        # Loki push, for the other machines' alloy and for LAN devices which
        # cannot join the tailnet, via loki.svc; see the router's coredns.nix.
        config.services.loki.configuration.server.http_listen_port
        # Plex, for LAN clients.
        32400
      ];
      allowedUDPPorts = [
        # Syslog from devices that cannot run alloy.
        5514
      ];
    };
  };

  systemd.network = {
    enable = true;

    # 1GbE management LAN.
    links."10-mgmt0" = {
      matchConfig.MACAddress = "04:d9:f5:7e:1c:47";
      linkConfig.Name = "mgmt0";
    };
    networks."10-mgmt0" = {
      matchConfig.Name = "mgmt0";
      networkConfig.DHCP = "ipv4";
      dhcpV4Config.ClientIdentifier = "mac";
      ipv6AcceptRAConfig = {
        # Only accept DNS search on this interface.
        UseDomains = true;
        # Use a fixed, MAC-free interface identifier for SLAAC addresses so
        # that the router's DNS records (see nixos/inventory/) are predictable.
        Token = "static:::10";
      };
    };

    # 10GbE bridge carrying the tagged container VLANs below. The host
    # itself is addressed only on mgmt0 among the site LANs: a second
    # address on the same LAN makes ingress asymmetric, and the firewall's
    # reverse path filter drops such traffic. Its dn42 address below is
    # another realm with routes of its own, so the two never overlap.
    netdevs."11-br0".netdevConfig = {
      Name = "br0";
      Kind = "bridge";
    };
    networks."11-br0" = {
      matchConfig.Name = "br0";
      networkConfig = {
        LinkLocalAddressing = "no";
        IPv6AcceptRA = false;
      };

      # Tagged VLANs carried over br0 for containers.
      vlan = [
        "dev0"
        "dn42i-dev0"
      ];
    };

    # Development VLAN, bridged into br-dev0 for containers (see dev.nix).
    # The host itself has no presence on it: no addresses, no RA.
    netdevs."12-dev0" = {
      netdevConfig = {
        Name = "dev0";
        Kind = "vlan";
      };
      vlanConfig.Id = inventory.interfaces.dev0.vlan;
    };
    networks."12-dev0" = {
      matchConfig.Name = "dev0";
      bridge = [ "br-dev0" ];
      networkConfig.LinkLocalAddressing = "no";
    };
    netdevs."12-br-dev0".netdevConfig = {
      Name = "br-dev0";
      Kind = "bridge";
    };
    # The internal dn42 VLAN, bridged into the development container as its
    # dn42 interface (see dev.nix). Named as the router names it, and with
    # the VLAN id from its dn42.nix, which owns this VLAN the way the
    # inventory owns the site LANs: its addressing is dn42 registry space,
    # so nothing about it is an inventory secret. Unlike dev0, the host is
    # present on it, with an address on the bridge (see dn42 above).
    netdevs."13-dn42i-dev0" = {
      netdevConfig = {
        Name = "dn42i-dev0";
        Kind = "vlan";
      };
      vlanConfig.Id = 42;
    };
    networks."13-dn42i-dev0" = {
      matchConfig.Name = "dn42i-dev0";
      bridge = [ "br-dn42i-dev0" ];
      networkConfig.LinkLocalAddressing = "no";
    };
    netdevs."13-br-dn42i-dev0".netdevConfig = {
      Name = "br-dn42i-dev0";
      Kind = "bridge";
    };
    # The host side of the development container's dn42 veth (see dev.nix).
    # nspawn creates and enslaves it, and systemd's own 80-container-vb
    # network covers only the primary vb-* veth, so without this it is
    # unmanaged and the kernel gives it a link-local address it has no use
    # for as a bridge port. Same treatment as that file, minus LLDP.
    networks."13-dn42-veth" = {
      matchConfig = {
        Kind = "veth";
        Name = "dn42";
      };
      networkConfig = {
        KeepMaster = true;
        LinkLocalAddressing = "no";
      };
      linkConfig.RequiredForOnline = "no";
    };
    # The host's dn42 address (see dn42 above), with link-local for
    # neighbor discovery. Not required for online: services wait on mgmt0.
    networks."13-br-dn42i-dev0" = {
      matchConfig.Name = "br-dn42i-dev0";
      address = [
        dn42.addr4
        dn42.addr6
      ];
      routes =
        map (net: {
          Destination = net;
          Gateway = dn42.router4;
          Metric = dn42.metric;
        }) dn42.routes4
        ++ map (net: {
          Destination = net;
          Gateway = dn42.router6;
          Metric = dn42.metric;
        }) dn42.routes6;
      networkConfig = {
        LinkLocalAddressing = "ipv6";
        IPv6AcceptRA = false;
        ConfigureWithoutCarrier = true;
      };
      linkConfig.RequiredForOnline = "no";
    };

    # MicroVM tap interfaces (see dev.nix) join the dev VLAN bridge, making
    # their guests dev0 citizens exactly like the containers.
    networks."12-vm-dev0" = {
      matchConfig.Name = "vm-*";
      bridge = [ "br-dev0" ];
      networkConfig.LinkLocalAddressing = "no";
      linkConfig.RequiredForOnline = "no";
    };
    networks."12-br-dev0" = {
      matchConfig.Name = "br-dev0";
      networkConfig = {
        LinkLocalAddressing = "no";
        IPv6AcceptRA = false;
        ConfigureWithoutCarrier = true;
      };
      linkConfig.RequiredForOnline = "no";
    };

    # 10GbE NIC tied to bridge.
    links."11-mgmt1" = {
      matchConfig.MACAddress = "8c:dc:d4:ac:96:24";
      linkConfig.Name = "mgmt1";
    };
    networks."11-mgmt1" = {
      matchConfig.Name = "mgmt1";
      bridge = [ "br0" ];
    };
  };
}
