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

  # Repositories cloned into ~/src on linuxdev, and pulled when that is safe.
  repos = [
    "bgpdev"
    "homelab"
  ];

  # Initial herdr configuration, copied into the user's config directory on
  # first boot only so that later edits win. Updates come from nixpkgs, not
  # herdr's self-updater; panes run login shells so PATH matches SSH logins.
  herdrConfig = pkgs.writeText "herdr-config.toml" ''
    [terminal]
    shell_mode = "login"

    [update]
    version_check = false
  '';

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
        shell = pkgs.bashInteractive;
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

            systemd.tmpfiles.rules = [
              "d ${home}/.config/herdr 0755 ${user} users -"
              "C ${home}/.config/herdr/config.toml 0644 ${user} users - ${herdrConfig}"
            ];

            # Re-run the clone job hourly so additions to repos appear without
            # a restart; the boot-time run comes from herdr-server's
            # ordering below.
            systemd.timers.dev-repos = {
              wantedBy = [ "timers.target" ];
              timerConfig.OnCalendar = "hourly";
            };

            systemd.services = {
              # Clone repositories into ~/src if they aren't there yet, and
              # fast-forward existing ones from GitHub when they are on main
              # with no local changes. Uses gh's credentials; skipped until
              # `gh auth login` has been run as the user.
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
                script =
                  "gh auth setup-git\n"
                  + lib.concatMapStrings (repo: ''
                    if [ ! -d ${src}/${repo} ]; then
                      gh repo clone mdlayher/${repo} ${src}/${repo}
                    elif [ "$(git -C ${src}/${repo} branch --show-current)" = "main" ] \
                      && git -C ${src}/${repo} diff --quiet \
                      && git -C ${src}/${repo} diff --cached --quiet; then
                      git -C ${src}/${repo} pull --ff-only
                    fi
                  '') repos;
              };

              # herdr's headless server, so the workspace and its agents come
              # back after a container restart before anyone attaches. Attach
              # with `herdr` inside, or `herdr --remote` from a desktop. If no
              # Claude Code agent is running after startup (nothing restored),
              # a workspace in ~/src is created with one, once Claude has been
              # logged in.
              herdr-server = {
                description = "herdr server";
                wantedBy = [ "multi-user.target" ];
                after = [
                  "network-online.target"
                  "dev-repos.service"
                ];
                wants = [
                  "network-online.target"
                  "dev-repos.service"
                ];
                path = [
                  pkgs.unstable.herdr
                  pkgs.fish
                  pkgs.bashInteractive
                  pkgs.jq
                ];
                serviceConfig = {
                  User = user;
                  WorkingDirectory = src;
                  ExecStart = "${pkgs.unstable.herdr}/bin/herdr server";
                  ExecStop = "${pkgs.unstable.herdr}/bin/herdr server stop";
                  Restart = "always";
                  RestartSec = "5s";
                };
                postStart = ''
                  for _ in $(seq 30); do
                    herdr status server >/dev/null 2>&1 && break
                    sleep 1
                  done
                  [ -f ${home}/.claude/.credentials.json ] || exit 0
                  if ! herdr agent list | grep -q claude; then
                    # Reuse an idle pane sitting in ~/src before creating one.
                    pane=$(herdr pane list | jq -r "[.result.panes[] | select(.cwd == \"${src}\" and .foreground_cwd == \"${src}\")][0].pane_id // empty")
                    if [ -z "$pane" ]; then
                      pane=$(herdr workspace create --cwd ${src} --label "~/src" | jq -r .result.root_pane.pane_id)
                    fi
                    herdr agent start claude --kind claude --pane "$pane" --timeout 120000
                  fi
                '';
              };
            };

            environment.systemPackages = with pkgs; [
              # Claude Code and its sandbox dependencies come from unstable to track
              # releases closely.
              unstable.claude-code

              # Persistent terminal workspace for agents; see herdr-server below.
              unstable.herdr

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
