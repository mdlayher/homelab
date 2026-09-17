{ lib, modulesPath, ... }:

# The pdx site: a single EC2 host in us-west-2, provisioned by
# terraform/aws. It is not a router in the sense routnerr-3 is -- no VLANs,
# no clients, nothing advertising itself -- it terminates one interconnect
# circuit and speaks the two routing protocols across it.
#
# Everything about the machine itself comes from the NixOS AMI's own module:
# the EC2 disk layout, growing the root partition, and the SSH key from
# instance metadata that the first deploy arrives over.
{
  imports = [
    (modulesPath + "/virtualisation/amazon-image.nix")

    ../modules/loopback.nix
    ./dn42.nix
    ./interconnect.nix
  ];

  # The dn42 and interconnect modules declare their interfaces as
  # systemd.network units, which are rendered but never applied unless
  # networkd owns the network. amazon-image.nix leaves eth0 to dhcpcd, so
  # without this the loopback, the carrier and the GRETAP simply do not
  # appear. useDHCP stays on: networkd's catch-all takes eth0 over, and
  # accepts the VPC's router advertisements for IPv6.
  networking.useNetworkd = true;

  # No LAN here, so nothing this host answers is reachable except over the
  # tailnet or the circuit. The carrier's port is the one exception, and the
  # security group in terraform/aws is what opens it from outside.
  networking.firewall = {
    enable = true;
    trustedInterfaces = [ "ts0" ];
  };

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
