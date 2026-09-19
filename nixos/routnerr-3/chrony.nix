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
  # Answered at every site, alongside the resolver (see coredns.nix). The
  # LANs keep the unicast server DHCP hands them: a client whose server can
  # change identity when the topology does is a property of anycast NTP,
  # worth having as a second source and not as the only one.
  homelab.anycast.services.ntp.unit = "chronyd.service";

  # Four operators on two continents, each serving NTS: enough authenticated
  # sources to outvote a falseticker without trusting any one of them. Never
  # a smeared source here - Google's and Meta's disagree with these around a
  # leap second.
  networking.timeServers = [
    "time.cloudflare.com"
    "virginia.time.system76.com"
    "nts.netnod.se"
    "ptbtime1.ptb.de"
  ];

  services.chrony = {
    enable = true;

    # Suffixes nts to every server above and keeps the cookies under the
    # state directory, so a restart resumes rather than repeating key
    # establishment. Client side only: the LANs are served plain NTP, which
    # is all timesyncd speaks.
    enableNTS = true;

    extraConfig = ''
      # The module writes no allow line, leaving chronyd a client alone.
      allow

      # Per client, for the dn42 side. A response is the size of its
      # request, so there is no amplification, but one peer's broken client
      # should not cost more than this.
      ratelimit interval 3 burst 8

      # NTS-KE is TLS, so a clock wrong enough cannot validate a certificate
      # and a pure NTS client whose RTC died never syncs at all. The pool is
      # the way out of that, and prefer keeps it out of selection whenever an
      # authenticated source is usable.
      pool 0.nixos.pool.ntp.org iburst
      authselectmode prefer
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
