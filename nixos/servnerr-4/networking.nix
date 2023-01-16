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

    # 10GbE LAN.
    links."12-tengb0" = {
      matchConfig.MACAddress = "90:e2:ba:23:1a:3a";
      linkConfig.Name = "tengb0";
    };
    networks."12-tengb0" = {
      # TODO(mdlayher): enable after setting up switch.
      enable = false;
      matchConfig.Name = "tengb0";
      networkConfig.DHCP = "ipv4";
      dhcpV4Config.ClientIdentifier = "mac";
    };
  };
}
