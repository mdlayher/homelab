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

  # The user inside the containers. The host's admin account provides its SSH
  # key and password hash.
  user = "mdlayher";
  home = "/home/${user}";
  src = "${home}/src";
  hostUser = config.users.users.${config.homelab.user};

  # The host's decrypted password hash, shared into each container so sudo
  # works with the same password.
  passwordHash = "/run/host-secrets/password_hash";

  # A dedicated non-FIDO SSH keypair for linuxdev, so agents there can reach
  # dev0 neighbors unattended: the VLAN is restricted and its posture is
  # effectively open between its own hosts. The private key is a sops secret
  # bind mounted into linuxdev only; every dev0 container accepts the public
  # key below.
  devSSHKey = "/run/host-secrets/dev_ssh_key";
  devSSHPublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIF9vB/Zp10y3S5plND/mb+eVzXe6/XCi1ysB2QApOiU9 linuxdev dev0";

  # Repositories cloned into ~/src on linuxdev, and pulled when that is safe.
  repos = [
    "bfd"
    "bgp"
    "bgpdev"
    "bmp"
    "consrv"
    "ethtool"
    "homelab"
    "ndp"
    "netlink"
    "socket"
    "vsock"
  ];

  # Initial herdr configuration, copied into the user's config directory on
  # first boot only so that later edits win; keep it mirroring the live
  # config inside the container. Updates come from nixpkgs, not herdr's
  # self-updater; panes run login shells so PATH matches SSH logins. Toasts
  # stay in-app (outer-terminal delivery proved noisy), and worktree
  # checkouts open under ~/src/worktrees.
  herdrConfig = pkgs.writeText "herdr-config.toml" ''
    onboarding = false

    [terminal]
    shell_mode = "login"

    [update]
    version_check = false

    [keys]
    focus_agent = "prefix+alt+1..9"

    [worktrees]
    directory = "~/src/worktrees"

    [ui]
    agent_panel_sort = "priority"
    status_indicators = "dots"
    show_agent_labels_on_pane_borders = false

    [ui.toast]
    delivery = "herdr"
  '';

  # Common configuration for a container on dev0: the base system from
  # modules/common.nix, addresses from the router (DHCPv4 plus SLAAC with a
  # fixed, MAC-free interface identifier matching the inventory's DNS record),
  # and SSH for the user.
  #
  # Note: pkgs is the host's package set, so pkgs.unstable comes from the
  # nixpkgs-unstable flake input.
  # Common configuration for a container on dev0. A null token means no fixed
  # IPv6 identifier and therefore no inventory entry or router deploy: the
  # container takes a pool DHCP lease and is reached as <hostName>.local over
  # mDNS. A non-null token pairs with an inventory host for a static lease and
  # a <name>.dev.lan.servnerr.com record.
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
      firewall = {
        allowedTCPPorts = [ 22 ];
        # mDNS, so dev0 hosts resolve each other as <name>.local without
        # router inventory entries (ephemeral containers in particular).
        allowedUDPPorts = [ 5353 ];
      };
    };

    systemd.network.networks."10-eth0" = {
      matchConfig.Name = "eth0";
      networkConfig = {
        DHCP = "ipv4";
        IPv6AcceptRA = true;
        MulticastDNS = true;
      };
      dhcpV4Config.ClientIdentifier = "mac";
      ipv6AcceptRAConfig = lib.mkIf (token != null) { Token = "static:::${token}"; };
    };

    services = {
      resolved = {
        enable = true;
        settings.Resolve.MulticastDNS = true;
      };
      openssh.enable = true;
    };

    users = {
      users.${user} = {
        isNormalUser = true;
        uid = 1000;
        extraGroups = [ "wheel" ];
        shell = pkgs.bashInteractive;
        hashedPasswordFile = passwordHash;
        openssh.authorizedKeys.keys = hostUser.openssh.authorizedKeys.keys ++ [ devSSHPublicKey ];
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
        hostPath = config.sops.secrets."users/mdlayher_password_hash".path;
        isReadOnly = true;
      };

      config.imports = [ (devModule hostName token) ] ++ modules;
    } extra;

  # FRR configuration for frrdev. The dev0 prefixes are inventory secrets, so
  # this is rendered by sops-nix on the host and bind mounted into the
  # container. Any external AS on dev0 may peer (dynamic neighbors); the
  # documentation prefixes are advertised without import checks so nothing
  # needs to exist in the container's routing table. BFD is offered on both
  # peer groups for interop testing against agent BFD implementations; peers
  # which never speak BFD still establish, since bgpd only tears down on an
  # up-to-down transition.
  frrConfig = ''
    hostname frrdev
    !
    router bgp 65001
     bgp router-id ${inventory.hosts."frrdev.dev".ipv4}
     no bgp ebgp-requires-policy
     no bgp network import-check
     neighbor DEV4 peer-group
     neighbor DEV4 remote-as external
     neighbor DEV4 bfd
     neighbor DEV6 peer-group
     neighbor DEV6 remote-as external
     neighbor DEV6 bfd
     bgp listen range ${dev0.ipv4Prefix}.0/24 peer-group DEV4
     bgp listen range ${dev0.ulaPrefix}::/64 peer-group DEV6
     !
     address-family ipv4 unicast
      network 192.0.2.0/24
      network 198.51.100.0/24
      network 203.0.113.0/24
      neighbor DEV6 activate
     exit-address-family
     !
     address-family ipv6 unicast
      network 2001:db8::/32
      network 2001:db8:1::/48
      network 2001:db8:2::/48
      neighbor DEV4 activate
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

              # herdr's headless server, so the workspace comes back after a
              # container restart before anyone attaches. Attach with `herdr`
              # inside, or `herdr --remote` from a desktop; agent panes then
              # resume their conversations via the Claude Code integration
              # (see ExecStartPre).
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
                  # The server shells out to git for worktree create/remove.
                  pkgs.git
                ];
                # Install the Claude Code integration (a hook in ~/.claude)
                # and the herdr skill before each start so both track the
                # herdr package version. The hook reports agent session IDs,
                # letting herdr resume conversations with `claude --resume`
                # after a restart; the skill lets a Claude session drive
                # herdr's panes and agents when asked.
                preStart = ''
                  herdr integration install claude
                  mkdir -p ${home}/.claude/skills/herdr
                  herdr --skill > ${home}/.claude/skills/herdr/SKILL.md
                '';
                serviceConfig = {
                  User = user;
                  WorkingDirectory = src;
                  ExecStart = "${pkgs.unstable.herdr}/bin/herdr server";
                  ExecStop = "${pkgs.unstable.herdr}/bin/herdr server stop";
                  Restart = "always";
                  RestartSec = "5s";
                };
              };
            };

            environment.systemPackages = with pkgs; [
              # Claude Code and its sandbox dependencies come from unstable to track
              # releases closely.
              unstable.claude-code

              # Persistent terminal workspace for agents; see herdr-server
              # below. Its Claude Code integration hook needs python3 to
              # report agent session IDs, and exits silently without it.
              unstable.herdr
              python3

              # Go toolchain and tooling; go-tools provides staticcheck. Takes
              # precedence over the base system's Go.
              (lib.hiPrio unstable.go_1_27)
              unstable.gopls
              gofumpt
              go-tools

              gh

              # logcli, for querying Loki logs over the tailnet; see
              # nixos/servnerr-4/loki.nix.
              grafana-loki
            ];

            # GitHub's published host key, pinned so SSH pushes (rewritten
            # from HTTPS by the shared gitconfig) verify without a
            # trust-on-first-use prompt.
            programs.ssh.knownHosts."github.com".publicKey =
              "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl";

            # SSH to the machines rides the tailnet (dev0 cannot reach the
            # LAN) and requires a FIDO2 touch per connection, so multiplex
            # connections: one touch covers a deploy's parallel sessions and
            # an hour of work. Short machine names come from the inventory
            # roles and resolve to tailnet names, so panes need no MagicDNS
            # search domain.
            programs.ssh.extraConfig =
              let
                machines = lib.flatten (lib.attrValues inventory.roles);
                # dev0 neighbors from the inventory, reached over the dev
                # VLAN by their LAN names, minus this container itself.
                neighbors = lib.filter (n: n != "linuxdev.dev") (map (h: h.name) dev0.hosts);
                shortName = n: lib.head (lib.splitString "." n);
              in
              ''
                Host ${lib.concatStringsSep " " machines} *.${inventory.tailnetDomain}
                  ControlMaster auto
                  ControlPath ~/.ssh/cm-%r@%h:%p
                  ControlPersist 1h
                  # sudo on the machines challenges the forwarded agent's
                  # FIDO2 keys in place of a password.
                  ForwardAgent yes
              ''
              + lib.concatMapStrings (m: ''
                Host ${m}
                  HostName ${m}.${inventory.tailnetDomain}
              '') machines
              # dev0 neighbors authenticate with the dedicated dev0 key (see
              # devSSHKey), touch-free; IdentitiesOnly keeps the forwarded
              # agent's FIDO2 keys out of authentication, though the agent is
              # still forwarded so sudo can challenge them. dev0 is untrusted
              # and gets no answers for the dev DNS records, so neighbors
              # resolve over mDNS as <name>.local; the *.local pattern also
              # covers ephemeral containers with no inventory entry.
              + lib.concatMapStrings (n: ''
                Host ${shortName n}
                  HostName ${shortName n}.local
              '') neighbors
              + ''
                Host ${lib.concatStringsSep " " (map shortName neighbors)} *.local
                  ForwardAgent yes
                  IdentityFile ${devSSHKey}
                  IdentitiesOnly yes
              '';

            # Per-repository dev shells (e.g. bgpdev's nix flake) activated on
            # cd via direnv, with nix-direnv caching the flake evaluation.
            # Skip the wall of exported variables on each activation; loading
            # notices and errors still print.
            programs.direnv = {
              enable = true;
              nix-direnv.enable = true;
              settings.global.hide_env_diff = true;
            };

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

          # The dev0 SSH private key, for this container only.
          bindMounts.${devSSHKey} = {
            hostPath = config.sops.secrets."dev/ssh_key".path;
            isReadOnly = true;
          };

          # linuxdev hosts long-lived agent sessions, so never restart it on a
          # host switch. Config changes are applied to the running container
          # with `systemctl reload container@linuxdev`, which activates the new
          # system inside via switch-to-configuration; changes to the container
          # scaffolding itself (bind mounts, networking, tun) still need a
          # manual `systemctl restart container@linuxdev`.
          restartIfChanged = false;
        };

    frrdev =
      devContainer "frrdev" "11"
        [
          {
            networking.firewall.allowedTCPPorts = [ 179 ];

            services.frr = {
              bgpd.enable = true;
              bfdd.enable = true;
              configFile = frrConfigFile;
            };

            # vtysh access for the user, plus the frr group so agents can
            # read frr-owned files (logs and the like) without sudo.
            users.users.${user}.extraGroups = [
              "frrvty"
              "frr"
            ];

            # Agents in this container operate FRR unattended, and sudo's
            # FIDO2 touch (or password) is unavailable to them. Allow daemon
            # lifecycle control of frr alone without authentication; the
            # verbs are enumerated so nothing interactive (e.g. systemctl
            # edit) rides along.
            security.sudo.extraRules = [
              {
                users = [ user ];
                commands =
                  lib.concatMap
                    (
                      verb:
                      map
                        (unit: {
                          command = "/run/current-system/sw/bin/systemctl ${verb} ${unit}";
                          options = [ "NOPASSWD" ];
                        })
                        [
                          "frr"
                          "frr.service"
                        ]
                    )
                    [
                      "start"
                      "stop"
                      "restart"
                      "reload"
                    ];
              }
            ];
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

  # Owned by the admin user (uid 1000, the user in the containers as well) so
  # ssh inside linuxdev can read it through the bind mount.
  sops.secrets."dev/ssh_key".owner = config.homelab.user;
}
