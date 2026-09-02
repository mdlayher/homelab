{ ... }:

{
  networking = {
    # Use systemd-networkd for configuration. Forcibly disable legacy DHCP client.
    useNetworkd = true;
    useDHCP = false;

    # Local firewall: the tailnet rides its own ACLs, SSH and tailscale open
    # their own ports, and the LAN may reach only the ports below.
    firewall = {
      trustedInterfaces = [ "ts0" ];
      allowedTCPPorts = [
        # consrv: svc:consrv is the usual path, but serial consoles are
        # break-glass access, so the trusted LAN keeps direct reach too.
        2222
        # Scraped by the server: node exporter, consrv metrics, alloy.
        9100
        9288
        12345
      ];
    };
  };

  systemd.network = {
    enable = true;

    # Onboard 1GbE on the management LAN. "end0" is the predictable name for
    # the device tree bcmgenet NIC on mainline kernels.
    networks."10-end0" = {
      matchConfig.Name = "end0";
      networkConfig.DHCP = "ipv4";
      dhcpV4Config.ClientIdentifier = "mac";
      # Only accept DNS search on this interface. SLAAC IIDs use networkd's
      # default EUI-64 derivation from the MAC, matching this host's "eui64"
      # mode in nixos/inventory/.
      ipv6AcceptRAConfig.UseDomains = true;
    };
  };
}
