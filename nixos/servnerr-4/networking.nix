{ config, ... }:

let
  inventory = config.homelab.inventory;
in
{
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
    # itself is addressed only on mgmt0: a second address on the same LAN
    # makes ingress asymmetric, and the firewall's reverse path filter
    # drops such traffic.
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
      vlan = [ "dev0" ];
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
