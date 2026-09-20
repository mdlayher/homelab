{
  config,
  lib,
  pkgs,
  ...
}:

let
  # dn42 (see dn42.nix): the registry delegates our domain and reverse
  # space to ns1, whose glue is the router's dn42 addresses. The zones
  # bind those two addresses alone, which nftables.nix opens on port 53;
  # a listener on a specific address takes every query to it, so the
  # wildcard root block never sees dn42, and other names are refused
  # there rather than recursed. All registry data, nothing to render.
  dn42 = config.homelab.dn42;

  inherit (import ../modules/reverse-zones.nix { inherit lib; }) nibbles6;

  # The reverse zones as the delegation servers cut them: RFC 2317 form,
  # 80/28.140.20.172.in-addr.arpa, for the /28; nibble boundary for the /48.
  net4 = lib.splitString "/" dn42.net4;
  octets4 = lib.splitString "." (lib.head net4);
  rev4 = "${lib.last octets4}/${lib.last net4}.${lib.concatStringsSep "." (lib.reverseList (lib.take 3 octets4))}.in-addr.arpa";
  # An address's owner name in that zone: its last octet.
  ptr4 = addr: lib.last (lib.splitString "." addr);

  net6 = lib.splitString "/" dn42.net6;
  net6Nibbles = lib.toInt (lib.last net6) / 4;
  rev6 = "${lib.concatStringsSep "." (lib.reverseList (lib.take net6Nibbles (nibbles6 (lib.head net6))))}.ip6.arpa";
  # An address's owner name in that zone: its remaining nibbles.
  ptr6 = addr: lib.concatStringsSep "." (lib.reverseList (lib.drop net6Nibbles (nibbles6 addr)));

  # The apex is the peering page, with single-family names beneath it as
  # on the clearnet and HTTPS records advertising HTTP/3 on all three;
  # the router's addresses, on the dummy and on the
  # internal VLAN, reverse to azo, the site's name as in
  # azo.dn42.mdlayher.net, whose names redirect to the apex's (see
  # dn42-page.nix). ntp is the NTP service for dn42 peers (see chrony.nix).
  # Owner names are relative to each file's zone, so the
  # shared SOA and NS are written out in full.
  dn42Soa = ''
    $TTL 3600
    @ IN SOA ns1.${dn42.domain}. hostmaster.${dn42.domain}. 1 7200 3600 1209600 3600
    @ IN NS ns1.${dn42.domain}.
  '';
  dn42Zone = pkgs.writeText "coredns-dn42.zone" ''
    ${dn42Soa}
    @ IN A ${dn42.addr4}
    @ IN AAAA ${dn42.addr6}
    @ IN HTTPS 1 . alpn="h3,h2"
    ipv4 IN A ${dn42.addr4}
    ipv4 IN HTTPS 1 . alpn="h3,h2"
    ipv6 IN AAAA ${dn42.addr6}
    ipv6 IN HTTPS 1 . alpn="h3,h2"
    ns1 IN A ${dn42.addr4}
    ns1 IN AAAA ${dn42.addr6}
    ntp IN A ${dn42.addr4}
    ntp IN AAAA ${dn42.addr6}
    azo IN A ${dn42.addr4}
    azo IN AAAA ${dn42.addr6}
    ipv4.azo IN A ${dn42.addr4}
    ipv6.azo IN AAAA ${dn42.addr6}
  '';
  dn42Rev4Zone = pkgs.writeText "coredns-dn42-rev4.zone" ''
    ${dn42Soa}
    ${ptr4 dn42.addr4} IN PTR azo.${dn42.domain}.
  '';
  dn42Rev6Zone = pkgs.writeText "coredns-dn42-rev6.zone" ''
    ${dn42Soa}
    ${ptr6 dn42.addr6} IN PTR azo.${dn42.domain}.
    ${lib.concatMapStringsSep "\n" (vlan: "${ptr6 vlan.addr6} IN PTR azo.${dn42.domain}.") (
      lib.attrValues dn42.vlans
    )}
  '';
in
{
  # The zones every site's resolver answers; this file adds dn42's, which
  # only the router is delegated.
  imports = [ ../modules/coredns.nix ];

  systemd.services.coredns = {
    # The dn42 zones bind the dn42 dummy's addresses, which networkd adds
    # after network.target: order after the device, and retry without a
    # start limit should they lag, rather than leave the LAN without DNS.
    # Ordering only: the LAN's resolver never depends on dn42.
    after = [ "sys-subsystem-net-devices-dn42.device" ];
    serviceConfig.RestartSec = "2s";
    unitConfig.StartLimitIntervalSec = 0;
  };

  services.coredns.config = lib.mkAfter ''
    # dn42, authoritative, on the ns1 addresses only (see dn42 above).
    # The zone names are public, so the zone-labelled metrics are fine.
    ${dn42.domain} ${rev4} ${rev6} {
      bind ${dn42.addr4} ${dn42.addr6}
      prometheus :9153
      file ${dn42Zone} ${dn42.domain}
      file ${dn42Rev4Zone} ${rev4}
      file ${dn42Rev6Zone} ${rev6}
    }

  '';
}
