{ lib, ... }:

let unstable = import <nixos-unstable-small> { };

in {
  networking = {
    # Host name and ID.
    hostName = "servnerr-4";
    hostId = "ed66dcdd";

    # Use systemd-networkd for configuration. Forcibly disable legacy DHCP client.
    useNetworkd = true;
    useDHCP = false;

    # No local firewall.
    firewall.enable = false;
  };

  services.tailscale = {
    enable = true;
    package = unstable.tailscale;
    interfaceName = "ts0";
  };

  # Tailscale readiness and DNS tweaks.
  systemd.network.wait-online.ignoredInterfaces = [ "ts0" ];

  systemd.services.tailscaled.after =
    [ "network-online.target" "systemd-resolved.service" ];

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
      # Only accept DNS search on this interface.
      ipv6AcceptRAConfig.UseDomains = true;
    };

    # 10GbE management LAN with bridge.
    netdevs."11-br0".netdevConfig = {
      Name = "br0";
      Kind = "bridge";
    };
    networks."11-br0" = {
      matchConfig.Name = "br0";
      networkConfig.DHCP = "ipv4";
      dhcpV4Config.ClientIdentifier = "mac";
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
