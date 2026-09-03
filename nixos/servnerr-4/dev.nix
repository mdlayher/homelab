# Development containers and microvms on the restricted dev0 VLAN, bridged
# via br-dev0 (see networking.nix). They can reach the internet and each
# other, but not the rest of the LAN.
#
# Containers share the host kernel and are the default; a microvm carries its
# own kernel for work the host kernel cannot do (out-of-tree modules), at the
# cost of a restart on every host switch which changes it.
#
# Each container has a dev0 entry in nixos/inventory/ for its static lease and
# DNS record; the veth MAC is read from the container after its first start,
# while a microvm's MAC is fixed here and copied into the inventory.
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

  # The secrets gate for linuxdev. A dedicated user holds the credentials
  # the admin uses from the container: an age identity that is a recipient
  # of the repository's sops files, and API tokens encrypted to it under
  # secrets/. Agents share the admin's uid, so the credentials live in a
  # uid of their own, reachable only through sudo -u, which pam_rssh gates
  # with a YubiKey touch on every invocation (no sudo cache; see common.nix).
  # Reads work by path: the gate user is in the users group and the admin's
  # home is group-readable in this container alone; writes need the group
  # write bit, which the admin's half grants for the duration of an edit.
  gateUser = "sops-gate";
  gateState = "/var/lib/${gateUser}";
  gateKey = "${gateState}/keys.txt";

  # The gated half, run as the gate user; its store path is the only
  # command the sudo rule permits. Plaintext (sops's editor temp file, the
  # tofu plan, the environment carrying a token) exists only in this uid.
  sopsGateRun = pkgs.writeShellApplication {
    name = "sops-gate-run";
    runtimeInputs = with pkgs; [
      age
      coreutils
      nano
      opentofu
      sops
    ];
    text = ''
      # Verbs:
      #   decrypt <file>                    print a sops file's plaintext
      #   edit <file>                       edit a sops file in place with nano
      #   exec-env <secrets> -- <cmd...>    run cmd with the file's values in its environment
      #   tofu-plan <module>                init and plan terraform/<module>
      #   tofu-apply <module>               init, plan, confirm on the tty, apply
      export SOPS_AGE_KEY_FILE=${gateKey}

      usage() {
        echo "usage: sops-gate {decrypt|edit} <file> | exec-env <secrets> -- <cmd...> | {tofu-plan|tofu-apply} <module>" >&2
        exit 2
      }

      # sops exec-env takes one string for /bin/sh -c; quote each argument.
      with_env() {
        local secrets=$1
        shift
        sops exec-env "$secrets" "$(printf '%q ' "$@")"
      }

      # terraform/<module> is read in place; everything tofu writes goes
      # under the gate's state directory in the usual layout: the state and
      # the plan beside a .terraform data dir holding provider plugins and
      # the backend record. The data dir must not be the state's own
      # directory, since tofu keeps that record at
      # $TF_DATA_DIR/terraform.tfstate, the same name as the state itself.
      # Credentials come from secrets/<module>.yaml.
      tofu_plan() {
        local module=$1 dir secrets state
        dir=terraform/$module
        secrets=secrets/$module.yaml
        state=${gateState}/tofu/$module
        if [[ ! -d $dir || ! -f $secrets ]]; then
          echo "sops-gate: $dir/ and $secrets must exist under the current directory" >&2
          exit 1
        fi
        export TF_DATA_DIR=$state/.terraform
        mkdir -p "$TF_DATA_DIR"
        tofu -chdir="$dir" init -input=false \
          -backend-config="path=$state/terraform.tfstate" >/dev/null
        with_env "$secrets" tofu -chdir="$dir" plan -input=false -out="$state/plan.tfplan"
      }

      tofu_apply() {
        local module=$1 answer
        tofu_plan "$module"
        read -r -p "sops-gate: apply this plan to $module? [y/N] " answer </dev/tty
        if [[ $answer != y ]]; then
          echo "sops-gate: not applied" >&2
          exit 1
        fi
        with_env "secrets/$module.yaml" tofu -chdir="terraform/$module" apply -input=false \
          "${gateState}/tofu/$module/plan.tfplan"
      }

      verb=''${1:-}
      shift || true
      case $verb in
        decrypt)
          [[ $# -eq 1 ]] || usage
          sops decrypt "$1"
          ;;
        edit)
          [[ $# -eq 1 ]] || usage
          EDITOR=nano sops edit "$1"
          ;;
        exec-env)
          [[ $# -ge 3 && $2 == -- ]] || usage
          secrets=$1
          shift 2
          with_env "$secrets" "$@"
          ;;
        tofu-plan)
          [[ $# -eq 1 ]] || usage
          tofu_plan "$1"
          ;;
        tofu-apply)
          [[ $# -eq 1 ]] || usage
          tofu_apply "$1"
          ;;
        *)
          usage
          ;;
      esac
    '';
  };

  # The admin's half, on PATH in linuxdev: escalates to the gate user for
  # every verb, and for edit first grants the group write bit sops needs
  # to rewrite the file in place. git does not carry the bit across
  # checkouts, so it is granted every time and taken back afterwards.
  sopsGate = pkgs.writeShellApplication {
    name = "sops-gate";
    text = ''
      if [[ ''${1:-} == edit && -n ''${2:-} ]]; then
        chmod g+w "$2"
        trap 'chmod g-w "$2"' EXIT
      fi
      /run/wrappers/bin/sudo -u ${gateUser} ${sopsGateRun}/bin/sops-gate-run "$@"
    '';
  };

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
  # checkouts open under ~/src, where each repo is a directory of one
  # worktree per branch (~/src/<repo>/main plus feature siblings).
  herdrConfig = pkgs.writeText "herdr-config.toml" ''
    onboarding = false

    [terminal]
    shell_mode = "login"

    [update]
    version_check = false

    [keys]
    focus_agent = "prefix+alt+1..9"

    [worktrees]
    directory = "~/src"

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
    # The raw inventory as flake.nix hands it to the machines, for shared
    # modules such as modules/tailscale.nix. The host's rendered copy
    # (config.homelab.inventory) carries sops placeholders which only the
    # host renders, so it is not the one to share.
    _module.args.inventory = import ../inventory;

    system.stateVersion = "26.05";

    networking = {
      inherit hostName;
      useNetworkd = true;
      useDHCP = false;
      # Own DNS via DHCP/RA and resolved rather than the host's resolv.conf.
      useHostResolvConf = false;
      firewall = {
        allowedTCPPorts = [
          22
          # BGP, so any dev0 container can accept peering.
          179
        ];
        allowedUDPPorts = [
          # single-hop BFD control, which conntrack never sees as a reply:
          # both endpoints send to destination port 3784, so each direction
          # must be admitted on its own.
          3784
          # mDNS, so dev0 hosts resolve each other as <name>.local without
          # router inventory entries (ephemeral containers in particular).
          5353
        ];
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

    # Packet capture for agents without sudo: cap_net_raw captures and
    # cap_net_admin flips promiscuous mode, while tcpdump itself runs as the
    # unprivileged user, so -z and -w carry no privilege. The capabilities
    # attach to this binary alone and are not inherited by its children.
    security.wrappers.tcpdump = {
      source = "${pkgs.tcpdump}/bin/tcpdump";
      capabilities = "cap_net_raw,cap_net_admin+ep";
      owner = "root";
      group = "users";
      permissions = "u+rx,g+rx";
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

  # A microvm on dev0, the VM analog of devContainer. The guest's tap
  # interface joins br-dev0 (see networking.nix), so it takes the same DHCP
  # lease, RA token, and mDNS presence as a container would. The MAC is the
  # guest's own and pairs with the host's inventory entry for its static
  # lease; the machine ID keeps the journal under one directory across
  # restarts.
  #
  # Monitoring works like a container's, not a machine's: dev0 cannot push
  # to Loki, so the guest journal is written through a virtiofs share to
  # /var/lib/microvms/<name>/journal, which the host's alloy ships (see
  # nixos/modules/alloy.nix), and the server scrapes node_exporter through
  # the guest's dev0 inventory entry (see prometheus.nix).
  devVM =
    hostName: token: mac: machineId: modules: extra:
    lib.recursiveUpdate {
      config = {
        imports = [ (devModule hostName token) ] ++ modules;

        # A VM is not detected the way a container is; take the container
        # semantics from common.nix explicitly (no sops, upgrades, or
        # hardware services).
        homelab.isMachine = false;

        # The host's password hash cannot be shared into the guest without
        # exposing a whole secrets directory over virtiofs, so the user has
        # no password: SSH is key-only regardless, sudo works when a
        # forwarded agent answers the FIDO2 challenge, and the qemu console
        # (host access only) logs in directly.
        users.users.${user}.hashedPasswordFile = lib.mkForce null;
        services.getty.autologinUser = user;

        # The home volume starts empty. Own the home directory explicitly:
        # tmpfiles otherwise creates it root-owned as the parent of the
        # entries devModule places under it, and the user cannot write
        # to their own home.
        systemd.tmpfiles.rules = [ "d ${home} 0700 ${user} users -" ];

        # The root filesystem is a tmpfs, so host keys under /etc would be
        # regenerated on every boot and clients would see a changed key
        # after each restart. Keep them on the persistent state volume.
        services.openssh.hostKeys = [
          {
            path = "/var/lib/ssh/ssh_host_ed25519_key";
            type = "ed25519";
          }
          {
            path = "/var/lib/ssh/ssh_host_rsa_key";
            type = "rsa";
            bits = 4096;
          }
        ];

        # The guest interface is named by PCI slot rather than eth0; match
        # the fixed MAC instead.
        systemd.network.networks."10-eth0".matchConfig = lib.mkForce {
          MACAddress = mac;
        };

        microvm = {
          hypervisor = "qemu";
          vcpu = 4;
          mem = 4096;
          inherit machineId;

          interfaces = [
            {
              type = "tap";
              id = "vm-${hostName}";
              inherit mac;
            }
          ];

          shares = [
            # The host store, read-only; the guest cannot build with nix.
            {
              tag = "ro-store";
              source = "/nix/store";
              mountPoint = "/nix/.ro-store";
              proto = "virtiofs";
            }
            # Guest journal, read by the host's alloy; see above.
            {
              tag = "journal";
              source = "/var/lib/microvms/${hostName}/journal";
              mountPoint = "/var/log/journal";
              proto = "virtiofs";
            }
          ];

          # Persistent state; paths are relative to
          # /var/lib/microvms/<name> on the host.
          volumes = [
            {
              image = "var.img";
              mountPoint = "/var";
              size = 4096;
            }
            {
              image = "home.img";
              mountPoint = "/home";
              size = 16384;
            }
          ];
        };
      };
    } extra;

  # The kernel QUIC module (IPPROTO_QUIC sockets) from lxin/quic, not yet
  # merged upstream or packaged in nixpkgs. Pinned by revision: upstream tags
  # no releases. One source for both the kernel module and its userspace
  # handshake library.
  quicSrc = pkgs.fetchFromGitHub {
    owner = "lxin";
    repo = "quic";
    rev = "bf47121683d987b0b20c79397704a6ae13911f88";
    hash = "sha256-FduHHKZRj01iXLw6F+71SVcFiSrVPtrNhETRMKbpdL0=";
  };
  quicVersion = "0-unstable-2026-08-19";

  # quic.ko built out of tree against the given kernel via kbuild directly:
  # the repo's autotools install step hardcodes /usr/include and runs depmod
  # and rmmod, none of which fit a Nix build.
  quicModules =
    kernel:
    pkgs.stdenv.mkDerivation {
      pname = "quic-modules";
      version = quicVersion;
      src = quicSrc;

      nativeBuildInputs = kernel.moduleBuildDependencies;

      # Upstream guards the kernel's recvmsg signature change behind a
      # placeholder future version; the change is already in 6.18.
      postPatch = ''
        substituteInPlace modules/net/quic/socket.c \
          --replace-fail "KERNEL_VERSION(7, 1, 0)" "KERNEL_VERSION(6, 18, 0)"
      '';

      # kernel.makeFlags is for building the kernel itself and breaks
      # external module builds; a native build needs nothing beyond kbuild's
      # own configuration.
      buildPhase = ''
        runHook preBuild
        make -j"$NIX_BUILD_CORES" \
          -C ${kernel.dev}/lib/modules/${kernel.modDirVersion}/build \
          M=$PWD/modules/net/quic ROOTDIR=$PWD/modules \
          CONFIG_IP_QUIC=m modules
        runHook postBuild
      '';

      installPhase = ''
        runHook preInstall
        install -Dm444 modules/net/quic/quic.ko \
          $out/lib/modules/${kernel.modDirVersion}/extra/quic.ko
        runHook postInstall
      '';
    };

  # libquic and headers: the userspace side of lxin/quic, which performs the
  # TLS handshake over a QUIC socket via gnutls and hands the connection to
  # the kernel.
  libquic = pkgs.stdenv.mkDerivation {
    pname = "libquic";
    version = quicVersion;
    src = quicSrc;

    nativeBuildInputs = with pkgs; [
      autoreconfHook
      pkg-config
    ];
    buildInputs = [ pkgs.gnutls ];

    configureFlags = [ "--without-modules" ];
  };

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
  # MicroVM host support for devVM above: per-VM systemd units, taps, and
  # virtiofs, with state under /var/lib/microvms.
  imports = [ inputs.microvm.nixosModules.host ];

  # QUIC protocol development against the kernel QUIC module. A VM rather
  # than a container: the module is out of tree, and loading experimental
  # kernel code on the server would put storage and every service in the
  # blast radius, while a VM confines a crash and lets the kernel change
  # without a host reboot. Reached from linuxdev as quicdev.local with the
  # shared dev0 SSH key, like any dev container.
  #
  # Unlike a container's veth, the MAC is chosen here and must match the
  # inventory's quicdev.dev entry (nixos/inventory/secrets.yaml) for the
  # router's static lease.
  microvm.vms.quicdev = devVM "quicdev" "12" "02:00:00:00:00:12" "5ebc7d0a-fa7b-70d0-8573-cb9552ed092c" [
    (
      { config, ... }:
      {
        boot = {
          # The machines' 2026 LTS kernel, with the QUIC module built
          # against it. The VM may diverge from the machines here freely,
          # e.g. to test newer kernels or the upstream patch series.
          kernelPackages = pkgs.linuxPackages_6_18;
          extraModulePackages = [ (quicModules config.boot.kernelPackages.kernel) ];
          kernelModules = [ "quic" ];
        };

        # Compile and link against libquic and gnutls outside nix builds
        # (the guest's store is read-only): ad hoc gcc and Go cgo find
        # headers and libraries through the system profile. Everything in
        # the profile comes from one nixpkgs evaluation, so the library
        # path stays coherent.
        environment = {
          systemPackages = [
            libquic
            pkgs.gnutls
            pkgs.gnutls.dev
          ];
          pathsToLink = [ "/include" ];
          variables = {
            CPATH = "/run/current-system/sw/include";
            LIBRARY_PATH = "/run/current-system/sw/lib";
            LD_LIBRARY_PATH = "/run/current-system/sw/lib";
            PKG_CONFIG_PATH = "/run/current-system/sw/lib/pkgconfig";
          };
        };
      }
    )
  ] { };

  containers = {
    linuxdev =
      devContainer "linuxdev" "10"
        [
          {
            networking.firewall.trustedInterfaces = [ "ts0" ];

            # Remote development from anywhere. Join once with `tailscale up`.
            #
            # The shared client module keeps accept-dns off and routes only
            # the tailnet domain to tailscaled via the tsdns0 dummy. Without
            # it, tailscaled's "~." route on ts0 outranks eth0's default and
            # the tailnet's DNS config takes over: public names go to its
            # global resolvers instead of the router, and the LAN domain is
            # split to the router's mgmt0 address, which dev0 cannot reach.
            # The dummy needs CAP_NET_ADMIN (granted with enableTun) and the
            # host's dummy driver, which the host's own tsdns0 keeps loaded.
            imports = [ ../modules/tailscale.nix ];

            # Tailscale SSH takes over port 22 for tailnet peers: logins are
            # authenticated by tailnet identity under the policy's ssh rules
            # (terraform/tailscale/policy.hujson), with no key on the client.
            # This is the break-glass path from a device that is not on the
            # tailnet, via the admin console's SSH Console in any browser.
            # sshd still serves dev0. Toggling the flag hangs connections
            # open to the container's tailnet address.
            services.tailscale.extraSetFlags = [ "--ssh" ];

            # The secrets gate; see sopsGateRun above. The admin's home is
            # group-readable here, and the gate user is the only other
            # member of users, so the worktree is readable by path from
            # the gated side and by nothing else.
            users = {
              users.${user}.homeMode = "750";
              users.${gateUser} = {
                isSystemUser = true;
                group = gateUser;
                extraGroups = [ "users" ];
                home = gateState;
              };
              groups.${gateUser} = { };
            };

            systemd.tmpfiles.rules = [
              "d ${home}/.config/herdr 0755 ${user} users -"
              "C ${home}/.config/herdr/config.toml 0644 ${user} users - ${herdrConfig}"
              "d ${gateState} 0700 ${gateUser} ${gateUser} -"
            ];

            # The gate's age identity, generated in place on first start.
            # The private key never leaves this directory; the recipient
            # is logged so it can be added to .sops.yaml.
            systemd.services.sops-gate-keygen = {
              description = "Generate the secrets gate age identity";
              wantedBy = [ "multi-user.target" ];
              path = [ pkgs.age ];
              serviceConfig = {
                Type = "oneshot";
                User = gateUser;
              };
              script = ''
                if [ ! -f ${gateKey} ]; then
                  (umask 077; age-keygen -o ${gateKey})
                  chmod 0400 ${gateKey}
                fi
                echo "recipient: $(age-keygen -y ${gateKey})"
              '';
            };

            # The one way into the gate: the admin may run the gated half
            # as the gate user, never as root, and every invocation costs a
            # touch since common.nix caches no sudo credentials. The wheel
            # rule from common.nix still exists, so this rule declares the
            # intended path rather than the only one; the touch is the gate
            # either way.
            security.sudo.extraRules = [
              {
                users = [ user ];
                runAs = gateUser;
                commands = [ { command = "${sopsGateRun}/bin/sops-gate-run"; } ];
              }
            ];

            # Re-run the clone job hourly so additions to repos appear without
            # a restart; the boot-time run comes from herdr-server's
            # ordering below.
            systemd.timers.dev-repos = {
              wantedBy = [ "timers.target" ];
              timerConfig.OnCalendar = "hourly";
            };

            systemd.services = {
              # Clone repositories into ~/src/<repo>/main if they aren't
              # there yet, and fast-forward existing ones from GitHub when
              # they are on main with no local changes and main tracks an
              # upstream: a repo mid-migration can sit on an upstream-less
              # main, and pulling there would fail the whole unit. Each repo
              # directory holds one worktree per branch, with main as the
              # primary clone; agents work in sibling worktrees, so this job
              # never contends with them for a checkout. Uses gh's
              # credentials; skipped until `gh auth login` has been run as
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
                script =
                  "gh auth setup-git\n"
                  + lib.concatMapStrings (repo: ''
                    if [ ! -d ${src}/${repo}/main ]; then
                      gh repo clone mdlayher/${repo} ${src}/${repo}/main
                    elif [ "$(git -C ${src}/${repo}/main branch --show-current)" = "main" ] \
                      && git -C ${src}/${repo}/main rev-parse --abbrev-ref 'main@{upstream}' >/dev/null 2>&1 \
                      && git -C ${src}/${repo}/main diff --quiet \
                      && git -C ${src}/${repo}/main diff --cached --quiet; then
                      git -C ${src}/${repo}/main pull --ff-only
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

              # The admin's half of the secrets gate; see sopsGate above.
              sopsGate
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
