# Development containers on the restricted dev0 VLAN, bridged via br-dev0 (see
# networking.nix). They can reach the internet and each other, but not the
# rest of the LAN.
#
# Each container has a dev0 entry in nixos/inventory/ for its static lease and
# DNS record; the veth MAC is read from the container after its first start.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  inventory = config.homelab.inventory;
  dev0 = inventory.interfaces.dev0;

  # The host's decrypted password hash for matt, shared into each container so
  # sudo works with the same password.
  passwordHash = "/run/host-secrets/matt_password_hash";

  # Common configuration for a container on dev0: addresses from the router
  # (DHCPv4 plus SLAAC with a fixed, MAC-free interface identifier matching
  # the inventory's DNS record), SSH for matt, and a few tools.
  #
  # Note: pkgs is the host's package set, so pkgs.unstable comes from the
  # nixpkgs-unstable flake input.
  devModule = hostName: token: {
    system.stateVersion = "26.05";

    networking = {
      inherit hostName;
      useNetworkd = true;
      useDHCP = false;
      # Own DNS via DHCP/RA and resolved rather than the host's resolv.conf.
      useHostResolvConf = false;
      firewall.allowedTCPPorts = [ 22 ];
    };

    systemd.network.networks."10-eth0" = {
      matchConfig.Name = "eth0";
      networkConfig = {
        DHCP = "ipv4";
        IPv6AcceptRA = true;
      };
      dhcpV4Config.ClientIdentifier = "mac";
      ipv6AcceptRAConfig.Token = "static:::${token}";
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
      bind
      curl
      fish
      git
      jq
      nano
      ripgrep
      tcpdump
      tmux
    ];
  };

  # A container on dev0. modules are added to the common configuration and
  # extra container settings are merged in.
  devContainer =
    hostName: token: modules: extra:
    lib.recursiveUpdate {
      autoStart = true;

      # Own network namespace, bridged onto the dev0 VLAN.
      privateNetwork = true;
      hostBridge = "br-dev0";

      bindMounts.${passwordHash} = {
        hostPath = config.sops.secrets."users/matt_password_hash".path;
        isReadOnly = true;
      };

      config.imports = [ (devModule hostName token) ] ++ modules;
    } extra;

  # FRR configuration for frrdev. The dev0 prefixes are inventory secrets, so
  # this is rendered by sops-nix on the host and bind mounted into the
  # container. Any external AS on dev0 may peer (dynamic neighbors); the
  # documentation prefixes are advertised without import checks so nothing
  # needs to exist in the container's routing table.
  frrConfig = ''
    hostname frrdev
    !
    router bgp 65001
     bgp router-id ${inventory.hosts."frrdev.dev".ipv4}
     no bgp ebgp-requires-policy
     no bgp network import-check
     neighbor DEV4 peer-group
     neighbor DEV4 remote-as external
     neighbor DEV6 peer-group
     neighbor DEV6 remote-as external
     bgp listen range ${dev0.ipv4Prefix}.0/24 peer-group DEV4
     bgp listen range ${dev0.ulaPrefix}::/64 peer-group DEV6
     !
     address-family ipv4 unicast
      network 192.0.2.0/24
      network 198.51.100.0/24
      network 203.0.113.0/24
      no neighbor DEV6 activate
     exit-address-family
     !
     address-family ipv6 unicast
      network 2001:db8::/32
      network 2001:db8:1::/48
      network 2001:db8:2::/48
      neighbor DEV6 activate
     exit-address-family
    exit
    !
  '';
  frrConfigFile = "/run/host-secrets/frr.conf";
in
{
  containers = {
    linuxdev =
      devContainer "linuxdev" "10"
        [
          {
            networking.firewall.trustedInterfaces = [ "ts0" ];

            # Remote development from anywhere. Join once with `tailscale up`.
            services.tailscale = {
              enable = true;
              package = pkgs.unstable.tailscale;
              interfaceName = "ts0";
            };

            environment.systemPackages = with pkgs; [
              # Claude Code and its sandbox dependencies come from unstable to track
              # releases closely.
              unstable.claude-code

              # Go toolchain.
              unstable.go_1_27
              gofumpt
              go-tools

              gh
            ];
          }
        ]
        {
          # Tailscale needs /dev/net/tun and CAP_NET_ADMIN.
          enableTun = true;
        };

    frrdev =
      devContainer "frrdev" "11"
        [
          {
            networking.firewall.allowedTCPPorts = [ 179 ];

            services.frr = {
              bgpd.enable = true;
              configFile = frrConfigFile;
            };

            # vtysh access for matt.
            users.users.matt.extraGroups = [ "frrvty" ];
          }
        ]
        {
          bindMounts.${frrConfigFile} = {
            hostPath = config.sops.templates."frr.conf".path;
            isReadOnly = true;
          };
        };
  };

  sops.templates."frr.conf" = {
    content = frrConfig;
    mode = "0444";
    restartUnits = [ "container@frrdev.service" ];
  };
}
