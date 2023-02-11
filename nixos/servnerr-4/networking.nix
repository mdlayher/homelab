{ lib, ... }:

{
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

    # 10GbE internal LAN.
    links."11-ten0p0lan0" = {
      matchConfig.MACAddress = "8c:dc:d4:ac:96:24";
      linkConfig.Name = "ten0p0lan0";
    };
    networks."11-ten0p0lan0" = {
      matchConfig.Name = "ten0p0lan0";
      networkConfig.DHCP = "ipv4";
      dhcpV4Config.ClientIdentifier = "mac";
      # Only accept DNS search on this interface.
      ipv6AcceptRAConfig.UseDomains = true;
    };

    # 10GbE lab VLAN.
    links."12-ten0p1lab0" = {
      matchConfig.MACAddress = "8c:dc:d4:ac:96:25";
      linkConfig.Name = "ten0p1lab0";
    };
    networks."12-ten0p1lab0" = {
      # TODO(mdlayher): enable after setting up bridge.
      enable = false;
      matchConfig.Name = "ten0p1lab0";
      networkConfig.DHCP = "ipv4";
      dhcpV4Config.ClientIdentifier = "mac";
      # Only accept DNS search on this interface.
      ipv6AcceptRAConfig.UseDomains = true;
    };
  };
}
