{ lib, ... }:

{
  networking = {
    # Host name and ID.
    hostName = "servnerr-3";
    hostId = "efdd2a1b";

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
      matchConfig.MACAddress = "1c:1b:0d:ea:83:0f";
      linkConfig.Name = "mgmt0";
    };
    networks."10-mgmt0" = {
      matchConfig.Name = "mgmt0";
      networkConfig.DHCP = "ipv4";
    };

    # 1GbE lab LAN, attached to br0 for VMs.
    links."11-lab0" = {
      matchConfig.MACAddress = "1c:1b:0d:ea:83:11";
      linkConfig.Name = "lab0";
    };
    netdevs."11-br0".netdevConfig = {
      Name = "br0";
      Kind = "bridge";
    };
    # TODO(mdlayher): enable after reconfiguring switch.
    networks."11-br0" = {
      enable = false;
      matchConfig.Name = "br0";
      networkConfig.DHCP = "ipv4";
    };
    networks."11-lab0" = {
      enable = false;
      matchConfig.Name = "lab0";
      networkConfig.Bridge = "br0";
    };

    # 10GbE LAN.
    links."12-tengb0" = {
      matchConfig.MACAddress = "90:e2:ba:5b:99:80";
      linkConfig.Name = "tengb0";
    };
    networks."12-tengb0" = {
      # TODO(mdlayher): enable after setting up switch.
      enable = false;
      matchConfig.Name = "tengb0";
      networkConfig.DHCP = "ipv4";
    };
  };
}
