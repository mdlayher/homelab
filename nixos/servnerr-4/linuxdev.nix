# linuxdev: an isolated development container for Claude Code and networking
# experiments, attached to the restricted dev0 VLAN via br-dev0 (see
# networking.nix). It can reach the internet and Tailscale, but not the rest
# of the LAN.
#
# Further containers for peering experiments (e.g. services.frr or
# services.bird) join the same VLAN by setting hostBridge = "br-dev0" and
# getting a dev0 entry in nixos/inventory/.
{ config, pkgs, ... }:

let
  # The host's decrypted password hash for matt, shared into the container so
  # sudo works with the same password.
  passwordHash = "/run/host-secrets/matt_password_hash";
in
{
  containers.linuxdev = {
    autoStart = true;

    # Own network namespace, bridged onto the dev0 VLAN. Tailscale needs
    # /dev/net/tun and CAP_NET_ADMIN.
    privateNetwork = true;
    hostBridge = "br-dev0";
    enableTun = true;

    bindMounts.${passwordHash} = {
      hostPath = config.sops.secrets."users/matt_password_hash".path;
      isReadOnly = true;
    };

    # Note: pkgs below is the host's package set, so pkgs.unstable comes from
    # the nixpkgs-unstable flake input.
    config = {
      system.stateVersion = "26.05";

      networking = {
        hostName = "linuxdev";
        useNetworkd = true;
        useDHCP = false;
        # Own DNS via DHCP/RA and resolved rather than the host's resolv.conf.
        useHostResolvConf = false;
        firewall = {
          allowedTCPPorts = [ 22 ];
          trustedInterfaces = [ "ts0" ];
        };
      };

      # Addresses from the router: DHCPv4 plus SLAAC with a fixed, MAC-free
      # interface identifier matching the inventory's DNS record.
      systemd.network.networks."10-eth0" = {
        matchConfig.Name = "eth0";
        networkConfig = {
          DHCP = "ipv4";
          IPv6AcceptRA = true;
        };
        dhcpV4Config.ClientIdentifier = "mac";
        ipv6AcceptRAConfig.Token = "static:::10";
      };

      i18n.defaultLocale = "en_US.UTF-8";
      time.timeZone = "America/Detroit";

      nix.settings.experimental-features = [
        "nix-command"
        "flakes"
      ];

      programs.fish.enable = true;

      services = {
        resolved.enable = true;

        # SSH keys only, never as root.
        openssh = {
          enable = true;
          settings = {
            PasswordAuthentication = false;
            KbdInteractiveAuthentication = false;
            PermitRootLogin = "no";
          };
        };

        # Remote development from anywhere. Join once with `tailscale up`.
        tailscale = {
          enable = true;
          package = pkgs.unstable.tailscale;
          interfaceName = "ts0";
        };
      };

      users = {
        mutableUsers = false;
        users.matt = {
          isNormalUser = true;
          uid = 1000;
          extraGroups = [ "wheel" ];
          shell = pkgs.fish;
          hashedPasswordFile = passwordHash;
          openssh.authorizedKeys.keys = config.users.users.matt.openssh.authorizedKeys.keys;
        };
      };

      environment.systemPackages = with pkgs; [
        # Claude Code and its sandbox dependencies come from unstable to track
        # releases closely.
        unstable.claude-code

        # Go toolchain.
        unstable.go_1_27
        gofumpt
        go-tools

        bind
        curl
        fish
        gh
        git
        jq
        nano
        ripgrep
        tcpdump
        tmux
      ];
    };
  };
}
