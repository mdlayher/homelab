{
  config,
  lib,
  modulesPath,
  ...
}:

# An edge on EC2: a single instance at a site with no LAN, provisioned by
# terraform/aws. It is not a router in the sense the router at azo is -- no
# VLANs, no clients, nothing advertising itself -- it terminates the
# circuits that reach its site and runs the IGP across them. Everything
# true of every edge is here; a site's own file names the site and, in its
# interconnect.nix, its circuits.
#
# Everything about the machine itself comes from the NixOS AMI's own module:
# the EC2 disk layout, growing the root partition, and the SSH key from
# instance metadata that the first deploy arrives over.
let
  inventory = config.homelab.inventory;

  # Our own IPv4 space as the firewall tests for it: the scheme's block and
  # the space the LANs still number from.
  site4 = "{ ${inventory.privatePrefix4}, ${inventory.legacyPrefix4} }";
in
{
  imports = [
    (modulesPath + "/virtualisation/amazon-image.nix")

    ./edge-chrony.nix
    ./edge-coredns.nix
    ./edge-tailscale.nix
    ./nftables-exporter.nix
  ];

  # The interconnect module declares its interfaces as systemd.network
  # units, which are rendered but never applied unless networkd owns the
  # network. amazon-image.nix leaves eth0 to dhcpcd, so without this the
  # loopback, the carriers and the GRETAPs simply do not appear. useDHCP
  # stays on: networkd's catch-all takes eth0 over, and accepts the VPC's
  # router advertisements for IPv6.
  networking.useNetworkd = true;

  # Forwarding for both families, declared here as the router declares it:
  # zebra turns it on at startup, and an edge on the ring transits between
  # its circuits, so it must not depend on which daemon happened to start.
  boot.kernel.sysctl = {
    "net.ipv4.conf.all.forwarding" = true;
    "net.ipv6.conf.all.forwarding" = true;
  };

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

    # The interconnect landing page (see icl-page.nix), and the HTTP-01
    # challenge that certifies it, are the only things here an arbitrary
    # client may reach. The security group in terraform/aws is what admits
    # them from outside; this admits them from anywhere else the machine is
    # reachable.
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
          9324 # bird exporter
          9342 # frr_exporter
          9586 # wireguard exporter
          9630 # nftables exporter
          9631 # dn42 peer exporter
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
        iifname "${link.interface}" ip6 saddr ${inventory.ulaPrefix6} tcp dport { ${ports tcp} } accept comment "site services across the circuit"
        iifname "${link.interface}" ip6 saddr ${inventory.ulaPrefix6} udp dport { ${ports udp} } accept comment "site services across the circuit"
        iifname "${link.interface}" ip saddr ${site4} tcp dport { ${ports tcp} } accept comment "site services across the circuit"
        iifname "${link.interface}" ip saddr ${site4} udp dport { ${ports udp} } accept comment "site services across the circuit"
      '') (lib.attrValues config.homelab.interconnect.links);
  };

  # Internal names resolve at the anycast resolver address, which is this
  # machine's own CoreDNS while it is serving and another site's while it is
  # not (see edge-coredns.nix). Routing domains rather than a search list:
  # an edge writes every name out in full, and nothing here should complete
  # a bare one. Routing domains rather than a plain DNS= for a second reason
  # -- eth0's DHCP servers also claim ".", and two unqualified claims on the
  # root make scope selection a coin toss.
  #
  # Everything else stays with the VPC resolver, so the nightly upgrade's
  # names do not depend on a resolver of ours being up.
  services.resolved.settings.Resolve = {
    DNS = [ inventory.anycast6.dns ];
    Domains = map (site: "~${site.domain}") (lib.attrValues inventory.sites) ++ [
      "~svc.${inventory.zone}"
      # dn42 as a whole: the resolver answers for it through the router, and
      # the VPC's would not.
      "~dn42"
    ];
  };

  # This site owns a /56 of the ULA and a /16 of the IPv4 space: a blanket
  # unreachable route for each, which the IGP originates on the site's
  # behalf (see the site's interconnect.nix) and which any more specific
  # prefix added here would supersede.
  systemd.network.networks."5-lo" = {
    matchConfig.Name = "lo";
    routes = [
      {
        Destination = inventory.sites.${config.homelab.site}.prefix6;
        Type = "unreachable";
      }
      {
        Destination = inventory.sites.${config.homelab.site}.prefix4;
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

  # No hardware-configuration.nix on an edge: amazon-image.nix is the
  # hardware, and it does not set a platform.
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
}
