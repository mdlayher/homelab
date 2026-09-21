{ ... }:

# NTP at an edge site, answering the anycast address alongside the other
# nodes holding it (see modules/anycast.nix). chronyd rather than the timesyncd this
# machine ran, which is a client alone; NixOS turns timesyncd off when
# chrony is enabled.
#
# The time itself comes from the Amazon Time Sync Service, which
# amazon-image.nix already names as this machine's server: a source inside
# the VPC, reached without leaving it.
#
# chronyd binds every address, so the anycast address appearing on the
# interface is all that is needed here. Nothing outside our own space
# reaches it: the firewall in configuration.nix admits the circuits by
# source address and the security group in terraform/aws opens no NTP port.
{
  homelab.anycast.services.ntp.unit = "chronyd.service";

  services.chrony = {
    enable = true;

    extraConfig = ''
      # The module writes no allow line, leaving chronyd a client alone.
      allow

      # Per client, as the router does. A response is the size of its
      # request, so there is no amplification.
      ratelimit interval 3 burst 8

      # A second opinion to compare the VPC's source against, so a source
      # which goes wrong can be outvoted rather than followed.
      pool 0.nixos.pool.ntp.org iburst
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
