{
  config,
  lib,
  modulesPath,
  ...
}:

# The edge at the pdx site: a single EC2 host in us-west-2, provisioned by
# terraform/aws. It is not a router in the sense routnerr-3 is -- no VLANs,
# no clients, nothing advertising itself -- it terminates one interconnect
# circuit and speaks the two routing protocols across it.
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

    ./interconnect.nix
  ];

  # The dn42 and interconnect modules declare their interfaces as
  # systemd.network units, which are rendered but never applied unless
  # networkd owns the network. amazon-image.nix leaves eth0 to dhcpcd, so
  # without this the loopback, the carrier and the GRETAP simply do not
  # appear. useDHCP stays on: networkd's catch-all takes eth0 over, and
  # accepts the VPC's router advertisements for IPv6.
  networking.useNetworkd = true;

  # The nftables backend, unlike the iptables one, can filter forwarding and
  # can match a source address in a rule of our own. An edge needs both: EC2
  # is told not to check source and destination, dn42 peering arrives with
  # the role, and the circuit carries other people's transit as well as our
  # traffic. filterForward lands now, while this machine forwards nothing at
  # all, rather than later when it would be a change with consequences.
  networking.nftables.enable = true;

  # No LAN here, so nothing this host answers is reachable except over the
  # tailnet or the circuit. The carrier's port is the one exception, and the
  # security group in terraform/aws is what opens it from outside.
  networking.firewall = {
    enable = true;
    trustedInterfaces = [ "ts0" ];
    filterForward = true;

    # Our own space is trusted across the circuit the way a LAN is; that is
    # what the circuit is for. The interface alone does not say that much --
    # dn42 transit arrives on it too -- so the rule is by source address,
    # and dn42's own space matches nothing here and meets the policy drop.
    extraInputRules = ''
      iifname "${config.homelab.interconnect.links.azo.interface}" ip6 saddr ${inventory.ulaPrefix} accept comment "site traffic across the circuit"
    '';
  };

  # Internal names resolve at the router across the circuit, which is the
  # only resolver that answers for them. Routing domains rather than a
  # search list: an edge writes every name out in full, and nothing here
  # should complete a bare one. Routing domains rather than a plain DNS=
  # for a second reason -- eth0's DHCP servers also claim ".", and two
  # unqualified claims on the root make scope selection a coin toss.
  #
  # Everything else stays with the VPC resolver, so the nightly upgrade's
  # names do not depend on a tunnel to a residential line.
  services.resolved.settings.Resolve = {
    DNS = [ inventory.sites.azo.loopbacks.${lib.head inventory.roles.router}.addr ];
    Domains = map (site: "~${site.domain}") (lib.attrValues inventory.sites) ++ [
      "~svc.${inventory.zone}"
      # dn42 as a whole, not just our zone within it: bird resolves the RTR
      # feeds by name (rpki.*.dn42), and the router is the only resolver
      # which forwards that TLD to dn42's own anycast servers.
      "~dn42"
    ];
  };

  # Never take a name from the VPC. UseHostname is the one that matters:
  # NixOS sets the static hostname and DHCP sets a transient one, the
  # transient wins for gethostname, and everything that reads it -- the
  # IS-IS dynamic hostname, the Loki host label -- has been reading EC2's
  # instead of this machine's.
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
  # refused, because the ssh policy grants only autogroup:member. Widening
  # that to tag:dev would be worse than the problem -- it would let the
  # development container in without the admin's key, and agents run there.
  #
  # The admin console's SSH Console is worth having on a machine with no LAN,
  # but it needs sshd on a second port to coexist with key-based deploys.
  # That is a decision to take before the public port closes, not a flag.
  services.tailscale.extraSetFlags = [ "--ssh=false" ];

  # Its own site, with no subnets: nothing here is named in internal DNS and
  # no inventory secret is decrypted. See nixos/inventory/.
  homelab.site = "pdx";

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
