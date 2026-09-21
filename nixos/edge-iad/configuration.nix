{
  config,
  lib,
  modulesPath,
  ...
}:

# The edge at the iad site: a single EC2 host in us-east-1, provisioned by
# terraform/aws. It is not a router in the sense routnerr-3 is -- no VLANs,
# no clients, nothing advertising itself -- it terminates the circuits that
# reach this site and runs the IGP across them.
#
# Everything about the machine itself comes from the NixOS AMI's own module:
# the EC2 disk layout, growing the root partition, and the SSH key from
# instance metadata that the first deploy arrives over.
let
  inventory = config.homelab.inventory;
in
{
  imports = [
    (modulesPath + "/virtualisation/amazon-image.nix")

    ../modules/edge-chrony.nix
    ../modules/edge-coredns.nix
    ../modules/nftables-exporter.nix
    ./interconnect.nix
  ];

  # The interconnect module declares its interfaces as systemd.network
  # units, which are rendered but never applied unless networkd owns the
  # network. amazon-image.nix leaves eth0 to dhcpcd, so without this the
  # loopback, the carriers and the GRETAPs simply do not appear. useDHCP
  # stays on: networkd's catch-all takes eth0 over, and accepts the VPC's
  # router advertisements for IPv6.
  networking.useNetworkd = true;

  # The nftables backend, unlike the iptables one, can filter forwarding and
  # can match a source address in a rule of our own. An edge needs both: EC2
  # is told not to check source and destination, and a circuit carries
  # traffic in transit to another site as well as traffic for this one.
  networking.nftables.enable = true;

  # No LAN here, so nothing this host answers is reachable except over the
  # tailnet or a circuit. The carriers' ports are the one exception, and the
  # security group in terraform/aws is what opens them from outside.
  networking.firewall = {
    enable = true;
    trustedInterfaces = [ "ts0" ];
    filterForward = true;

    # The interconnect landing page (see modules/icl-page.nix), and the
    # HTTP-01 challenge that certifies it, are the only things here an
    # arbitrary client may reach. The security group in terraform/aws is
    # what admits them from outside; this admits them from anywhere else
    # the machine is reachable.
    allowedTCPPorts = [
      80
      443
    ];

    # What our own space may reach across a circuit, by source address as
    # well as interface: the interface alone does not say that much, since
    # a circuit also carries traffic that is only passing through.
    #
    # Named ports rather than the whole machine. A source in our own space
    # is not by itself a trusted party: every segment at another site draws
    # from this prefix, restricted ones included, so a blanket accept here
    # puts each of them in front of every port this machine listens on. The
    # list is what has to cross -- the exporters the server scrapes, and the
    # services this site answers for when it is the nearest node holding an
    # anycast address.
    #
    # One rule per circuit, from the links themselves, so a circuit to a new
    # site is reachable without a second place to remember.
    extraInputRules =
      let
        tcp = [
          9100 # node_exporter
          9123 # chrony exporter
          9153 # coredns
          9342 # frr_exporter
          9586 # wireguard exporter
          9630 # nftables exporter
          12345 # alloy
          53 # resolver, when this site is the nearest node holding it
        ];
        udp = [
          53
          123 # NTP, on the same terms as the resolver
        ];
        ports = p: lib.concatMapStringsSep ", " toString p;
      in
      lib.concatMapStrings (link: ''
        iifname "${link.interface}" ip6 saddr ${inventory.ulaPrefix} tcp dport { ${ports tcp} } accept comment "site services across the circuit"
        iifname "${link.interface}" ip6 saddr ${inventory.ulaPrefix} udp dport { ${ports udp} } accept comment "site services across the circuit"
      '') (lib.attrValues config.homelab.interconnect.links);
  };

  # Internal names resolve at the anycast resolver address, which is this
  # machine's own CoreDNS while it is serving and another site's while it is
  # not (see modules/edge-coredns.nix). Routing domains rather than a search
  # list: an edge writes every name out in full, and nothing here should
  # complete a bare one. Routing domains rather than a plain DNS= for a
  # second reason -- eth0's DHCP servers also claim ".", and two unqualified
  # claims on the root make scope selection a coin toss.
  #
  # Everything else stays with the VPC resolver, so the nightly upgrade's
  # names do not depend on a resolver of ours being up.
  services.resolved.settings.Resolve = {
    DNS = [ inventory.anycast.dns ];
    Domains = map (site: "~${site.domain}") (lib.attrValues inventory.sites) ++ [
      "~svc.${inventory.zone}"
      # dn42 as a whole: the resolver answers for it through the router, and
      # the VPC's would not.
      "~dn42"
    ];
  };

  # This site owns a /56 of the ULA: a blanket unreachable route, which the
  # IGP originates on the site's behalf (see interconnect.nix) and which any
  # more specific prefix added here would supersede.
  systemd.network.networks."5-lo" = {
    matchConfig.Name = "lo";
    routes = [
      {
        Destination = inventory.sites.${config.homelab.site}.prefix;
        Type = "unreachable";
      }
    ];
  };

  # Never take a name from the VPC. UseHostname is the one that matters:
  # NixOS sets the static hostname and DHCP sets a transient one, the
  # transient wins for gethostname, and everything that reads it -- the
  # IS-IS dynamic hostname, the Loki host label -- would read EC2's instead
  # of this machine's.
  systemd.network.networks."99-ethernet-default-dhcp" = {
    dhcpV4Config = {
      UseDomains = false;
      UseHostname = false;
    };
    ipv6AcceptRAConfig.UseDomains = false;
  };

  # Not Tailscale SSH, and the negative is declared rather than left to
  # whatever the node was last told by hand. Turning it on makes tailscaled
  # answer port 22 for every tailnet connection, which takes the port away
  # from sshd: the deploys that ride tag:dev reach tailscaled instead and are
  # refused, because the ssh policy grants only autogroup:member.
  services.tailscale.extraSetFlags = [ "--ssh=false" ];

  # Its own site, with no subnets: nothing here is named in internal DNS and
  # no inventory secret is decrypted. See nixos/inventory/.
  homelab.site = "iad";

  # No hardware-configuration.nix here: amazon-image.nix is the hardware,
  # and it does not set a platform.
  nixpkgs.hostPlatform = "x86_64-linux";

  # common.nix turns these on for every machine, and none of them has
  # anything to act on here: EBS reports no SMART data and there is no
  # firmware to update. fwupd also pulls in udisks2, which the EC2 image
  # module turns off, so leaving it on is an eval conflict rather than
  # merely a useless unit.
  services.fwupd.enable = lib.mkForce false;
  services.smartd.enable = lib.mkForce false;
  services.prometheus.exporters.smartctl.enable = lib.mkForce false;

  # amazon-image.nix permits key-based root login, which is how the stock
  # AMI is reachable at all. common.nix's "no" is the posture every other
  # machine has, so it wins here too: the first deploy goes in as root
  # against the AMI's own sshd (DEPLOY_USER=root), and once it lands the
  # admin user from common.nix takes over with the same key -- it is the
  # key terraform/aws puts in the EC2 key pair.
  services.openssh.settings.PermitRootLogin = lib.mkForce "no";

  system.stateVersion = "26.05";
}
