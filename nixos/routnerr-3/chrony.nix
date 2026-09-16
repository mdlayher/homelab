# NTP for the homelab and for dn42: chrony on the router, the one host on
# every LAN and on dn42.
#
# Clients configure nothing. The DHCPv4 server hands each LAN its own router
# address (see networking.nix) and timesyncd prefers a link's servers over
# its pool; RAs carry no NTP option, but every LAN is dual stack. Containers
# are inert - timesyncd's unit conditions exclude them - and follow the host.
#
# chronyd binds every address and nftables.nix decides who may ask, as with
# CoreDNS: the trusted LANs as for any router service, the restricted LANs
# and both dn42 classes by an explicit rule, the WANs not at all.
{ ... }:

{
  # The default is four pool directives, and chrony draws four sources from
  # each. One pool is the four it wants; Cloudflare's anycast adds a second
  # operator, since this clock is now the whole homelab's. Never a smeared
  # source here - Google's and Meta's disagree with these around a leap
  # second - and NTS would have to replace the pool, not join it.
  networking.timeServers = [
    "time.cloudflare.com"
    "0.nixos.pool.ntp.org"
  ];

  services.chrony = {
    enable = true;

    extraConfig = ''
      # The module writes no allow line, leaving chronyd a client alone.
      allow

      # Per client, for the dn42 side. A response is the size of its
      # request, so there is no amplification, but one peer's broken client
      # should not cost more than this.
      ratelimit interval 3 burst 8
    '';
  };

  # Scraped without change on the server, which discovers each enabled
  # exporter from this configuration (see nixos/servnerr-4/prometheus.nix).
  services.prometheus.exporters.chrony.enable = true;

  # The command socket exists only once chronyd is up, and it is
  # Type=notify. Without this the exporter's Restart=on-failure can hit its
  # start limit and stay dead through a boot where chronyd was slow.
  systemd.services.prometheus-chrony-exporter.after = [ "chronyd.service" ];
}
