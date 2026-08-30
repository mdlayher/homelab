# Development containers on the restricted dev0 VLAN, bridged via br-dev0 (see
# networking.nix). They can reach the internet and each other, but not the
# rest of the LAN.
#
# Each container has a dev0 entry in nixos/inventory/ for its static lease and
# DNS record; the veth MAC is read from the container after its first start.
{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:

let
  inventory = config.homelab.inventory;
  dev0 = inventory.interfaces.dev0;

  # The user inside the containers. The host's matt account provides its SSH
  # key and password hash, but the name is mdlayher going forward.
  user = "mdlayher";
  home = "/home/${user}";
  src = "${home}/src";
  hostUser = config.users.users.matt;

  # The host's decrypted password hash, shared into each container so sudo
  # works with the same password.
  passwordHash = "/run/host-secrets/password_hash";

  # Repositories cloned into ~/src on linuxdev.
  repos = [ "bgpdev" ];

  # Common configuration for a container on dev0: the base system from
  # modules/common.nix, addresses from the router (DHCPv4 plus SLAAC with a
  # fixed, MAC-free interface identifier matching the inventory's DNS record),
  # and SSH for the user.
  #
  # Note: pkgs is the host's package set, so pkgs.unstable comes from the
  # nixpkgs-unstable flake input.
  devModule = hostName: token: {
    # The container's own package set needs the unstable overlay for
    # common.nix, and common.nix's sops options must exist even though it
    # declares secrets for machines only.
    imports = [
      ../modules/common.nix
      ../modules/unstable.nix
      inputs.sops-nix.nixosModules.sops
    ];
    _module.args.inputs = inputs;

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

    services = {
      resolved.enable = true;
      openssh.enable = true;
    };

    users = {
      users.${user} = {
        isNormalUser = true;
        uid = 1000;
        extraGroups = [ "wheel" ];
        shell = pkgs.fish;
        hashedPasswordFile = passwordHash;
        openssh.authorizedKeys.keys = hostUser.openssh.authorizedKeys.keys;
      };
    };
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

            # Re-run the clone job hourly so additions to repos appear without
            # a restart; the boot-time run comes from claude-remote-control's
            # ordering below.
            systemd.timers.dev-repos = {
              wantedBy = [ "timers.target" ];
              timerConfig.OnCalendar = "hourly";
            };

            systemd.services = {
              # Clone repositories into ~/src if they aren't there yet, using
              # gh's credentials. Skipped until `gh auth login` has been run as
              # the user.
              dev-repos = {
                description = "Clone development repositories";
                after = [ "network-online.target" ];
                wants = [ "network-online.target" ];
                unitConfig.ConditionPathExists = "${home}/.config/gh/hosts.yml";
                path = [
                  pkgs.gh
                  pkgs.git
                ];
                serviceConfig = {
                  Type = "oneshot";
                  User = user;
                  WorkingDirectory = home;
                };
                script = lib.concatMapStrings (repo: ''
                  if [ ! -d ${src}/${repo} ]; then
                    gh repo clone mdlayher/${repo} ${src}/${repo}
                  fi
                '') repos;
              };

              # Claude Code server mode, so the Claude app can attach sessions
              # via Remote Control. Claude insists on a terminal and a consent
              # prompt, so it runs in a detached tmux session on its own tmux
              # server, out of byobu's reach (attach with `tmux -L claude
              # attach`), and the prompt is answered automatically. Starts once `claude auth login` has been run as
              # the user; sessions start in ~/src, since Claude Code never
              # trusts a home directory itself.
              claude-remote-control = {
                description = "Claude Code Remote Control";
                wantedBy = [ "multi-user.target" ];
                after = [
                  "network-online.target"
                  "dev-repos.service"
                ];
                wants = [
                  "network-online.target"
                  "dev-repos.service"
                ];
                unitConfig.ConditionPathExists = "${home}/.claude/.credentials.json";
                path = [
                  pkgs.tmux
                  pkgs.unstable.claude-code
                ];
                environment.TERM = "xterm-256color";
                serviceConfig = {
                  # The tmux server is the main process; the unit ends and
                  # restarts when Claude exits and the session closes.
                  Type = "forking";
                  User = user;
                  WorkingDirectory = src;
                  ExecStart = "${pkgs.tmux}/bin/tmux -L claude new-session -d -s claude claude remote-control --name linuxdev";
                  ExecStop = "${pkgs.tmux}/bin/tmux -L claude kill-server";
                  Restart = "always";
                  RestartSec = "10s";
                };
                # Answer the consent prompt if it appears.
                postStart = ''
                  for _ in $(seq 30); do
                    if tmux -L claude capture-pane -p -t claude 2>/dev/null | grep -q "Enable Remote Control"; then
                      tmux -L claude send-keys -t claude y
                      break
                    fi
                    sleep 1
                  done
                '';
              };
            };

            environment.systemPackages = with pkgs; [
              # Claude Code and its sandbox dependencies come from unstable to track
              # releases closely.
              unstable.claude-code

              # Go toolchain and tooling; go-tools provides staticcheck. Takes
              # precedence over the base system's Go.
              (lib.hiPrio unstable.go_1_27)
              unstable.gopls
              gofumpt
              go-tools

              gh
            ];

            # Let the VS Code Remote-SSH server, which VS Code downloads as a
            # prebuilt dynamically linked binary, run on NixOS.
            programs.nix-ld = {
              enable = true;
              libraries = with pkgs; [
                stdenv.cc.cc.lib
                zlib
              ];
            };
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

            # vtysh access for the user.
            users.users.${user}.extraGroups = [ "frrvty" ];
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
