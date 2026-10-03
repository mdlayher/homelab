# The KVM's configuration: every file this repository manages on the PiKVM,
# built as a tree with a manifest for pikvm/deploy to apply. The device runs
# PiKVM OS rather than NixOS, so the files are rendered here from the same
# data the machines read and copied into place over SSH.
{
  lib,
  pkgs,
  go,
  inventory,
  sshKeys,
  # Loki's port on the server, from its configuration.
  lokiPort,
}:

let
  # consrv for the serial consoles, a static arm64 binary for PiKVM OS. Go
  # cross-compiles it, so the binary moves out of GOPATH's per-platform
  # directory, and the build machine's strip and patchelf stay off it.
  consrv = (pkgs.buildGoModule.override { inherit go; }) {
    pname = "consrv";
    version = "1.3.0";

    src = pkgs.fetchFromGitHub {
      owner = "mdlayher";
      repo = "consrv";
      rev = "v1.3.0";
      hash = "sha256-0tUt4fXqpWLmGXo9S4KBHafbyDickfbOCjLpZXERsDk=";
    };

    vendorHash = "sha256-/kU1hGu1LLHxy7Df7bu+9Qg6upu23BcV8j7xVOMFcTA=";

    subPackages = [ "cmd/consrv" ];
    env.CGO_ENABLED = "0";
    ldflags = [
      "-s"
      "-w"
    ];

    # buildGoModule sets GOARCH for the build machine during configure.
    preBuild = ''
      export GOOS=linux GOARCH=arm64
    '';
    postInstall = ''
      mv $out/bin/linux_arm64/consrv $out/bin/consrv
      rmdir $out/bin/linux_arm64
    '';
    dontStrip = true;
    dontPatchELF = true;
    doCheck = false;
  };

  # The serial consoles consrv serves, by USB adapter serial number.
  consoles = {
    router = "Q3245527461";
    server = "A64NMAJS";
  };

  linuxdev = inventory.tailnetHosts.linuxdev;

  # The site whose LAN the KVM is on, for the label every log stream
  # carries; see nixos/modules/alloy.nix.
  site = lib.findFirst (
    name:
    lib.any (subnet: (subnet.hosts or { }) ? pikvm) (
      lib.attrValues (inventory.sites.${name}.subnets or { })
    )
  ) null (lib.attrNames inventory.sites);
  tailscalePort = (lib.findFirst (f: f.host == "pikvm") null inventory.tailscaleForwards).port;

  # Packages the managed files belong to, installed by hand (see README.md);
  # apply.sh refuses to change anything while one is missing.
  packages = [
    "grafana-alloy"
    "modemmanager"
    "networkmanager"
    "prometheus-node-exporter"
    "tailscale-pikvm"
  ];

  # Each managed file: its path on the device, mode, contents, and what
  # applying a change to it takes (see apply.sh).
  files = [
    {
      path = "/etc/kvmd/override.yaml";
      mode = "644";
      action = "kvmd";
      # Prometheus scrapes the metrics without a login: every kvmd user has
      # full control of the server, so no credential is held there.
      text = ''
        kvmd:
            prometheus:
                auth:
                    enabled: false
      '';
    }
    {
      path = "/etc/default/tailscaled";
      mode = "644";
      action = "tailscaled";
      text = ''
        PORT="${toString tailscalePort}"
        FLAGS="--tun=ts0"
      '';
    }
    {
      path = "/etc/ssh/sshd_config.d/10-homelab.conf";
      mode = "644";
      action = "sshd";
      text = ''
        PasswordAuthentication no
        KbdInteractiveAuthentication no
        PermitRootLogin prohibit-password
      '';
    }
    {
      path = "/etc/ssh/sshd_config.d/99-fido-from-container.conf";
      mode = "644";
      action = "sshd";
      text = ''
        # SSH from the development container accepts only the admin's FIDO2
        # keys, so every login from there needs a physical YubiKey touch.
        Match User root Address ${linuxdev.ipv4},${linuxdev.ipv6}
            AuthorizedKeysFile /etc/ssh/root_fido_keys
      '';
    }
    {
      path = "/etc/ssh/root_fido_keys";
      mode = "644";
      action = "none";
      text = lib.concatLines sshKeys.fido;
    }
    {
      path = "/root/.ssh/authorized_keys";
      mode = "600";
      action = "none";
      text = lib.concatLines ([ sshKeys.admin ] ++ sshKeys.fido);
    }
    {
      # NetworkManager runs for the LTE modem alone; systemd-networkd keeps
      # the wired interface.
      path = "/etc/NetworkManager/conf.d/pikvm-unmanaged.conf";
      mode = "644";
      action = "networkmanager";
      text = ''
        [keyfile]
        unmanaged-devices=*,except:type:gsm
      '';
    }
    {
      path = "/etc/NetworkManager/system-connections/pikvm-lte.nmconnection";
      mode = "600";
      action = "networkmanager";
      text = ''
        [connection]
        id=pikvm-lte
        uuid=1ca18f28-1d2e-492d-acc0-22b373c634c2
        type=gsm

        [gsm]
        apn=h2g2

        [ipv4]
        method=auto

        [ipv6]
        addr-gen-mode=default
        method=auto

        [proxy]
      '';
    }
    {
      # The collectors and flags the machines' node exporters run with; see
      # nixos/modules/common.nix.
      path = "/etc/conf.d/prometheus-node-exporter";
      mode = "644";
      action = "node-exporter";
      text = ''
        NODE_EXPORTER_ARGS="--collector.systemd --collector.systemd.enable-restarts-metrics --collector.systemd.enable-start-time-metrics"
      '';
    }
    {
      path = "/etc/default/grafana-alloy";
      mode = "644";
      action = "alloy";
      text = ''
        CONFIG_FILE="/etc/grafana-alloy/config.alloy"
        CUSTOM_ARGS="--server.http.listen-addr=0.0.0.0:12345 --disable-reporting"
      '';
    }
    {
      # The journal lives in a tmpfs (/var/log) and starts over at every
      # boot, so Alloy's storage, which holds its place in the journal,
      # lives in /run alongside it. It is kept across restarts of the
      # service, which would otherwise ship the journal again.
      path = "/etc/systemd/system/grafana-alloy.service.d/pikvm.conf";
      mode = "644";
      action = "alloy";
      text = ''
        [Service]
        RuntimeDirectory=grafana-alloy
        RuntimeDirectoryPreserve=yes
        WorkingDirectory=/run/grafana-alloy
        ExecStart=
        ExecStart=/usr/bin/grafana-alloy run $CUSTOM_ARGS --storage.path=/run/grafana-alloy/data $CONFIG_FILE
      '';
    }
    {
      # The journal to Loki on the server by its service name, labeled as
      # the machines' journals are; see nixos/modules/alloy.nix.
      path = "/etc/grafana-alloy/config.alloy";
      mode = "644";
      action = "alloy";
      comment = "//";
      text = ''
        loki.relabel "journal" {
          forward_to = []

          rule {
            source_labels = ["__journal__hostname"]
            target_label  = "host"
          }

          rule {
            source_labels = ["__journal__systemd_unit"]
            target_label  = "unit"
          }

          rule {
            source_labels = ["unit"]
            regex         = "sshd@.+"
            replacement   = "sshd.service"
            target_label  = "unit"
          }

          rule {
            source_labels = ["unit"]
            regex         = "session-.+\\.scope"
            replacement   = "session.scope"
            target_label  = "unit"
          }
        }

        loki.source.journal "journal" {
          forward_to    = [loki.write.server.receiver]
          relabel_rules = loki.relabel.journal.rules
          labels        = {job = "systemd-journal", site = "${site}"}
        }

        loki.write "server" {
          endpoint {
            url = "http://loki.svc.${inventory.zone}:${toString lokiPort}/loki/api/v1/push"
          }
        }
      '';
    }
    {
      path = "/etc/consrv.toml";
      mode = "644";
      action = "consrv";
      text = ''
        # consrv on the PiKVM: SSH to the serial consoles attached to it.
      ''
      + lib.concatMapStrings (name: ''
        [[devices]]
        name = "${name}"
        serial = "${consoles.${name}}"
        baud = 115200
        identities = ["mdlayher"]

      '') (lib.attrNames consoles)
      + ''
        [[identities]]
        name = "mdlayher"
        public_key = "${sshKeys.admin}"

        [debug]
        address = ":9288"
        prometheus = true
      '';
    }
    {
      path = "/etc/systemd/system/consrv.service";
      mode = "644";
      action = "consrv";
      text = builtins.readFile ./consrv.service;
    }
    {
      path = "/usr/local/bin/consrv";
      mode = "755";
      action = "consrv";
      binary = "${consrv}/bin/consrv";
    }
  ];

  # Every text file opens with this, in its comment syntax (# unless the
  # file says otherwise), so an edit made on the device is recognizable as
  # one the next deploy overwrites.
  header = comment: ''
    ${comment} Managed by pikvm/deploy from the homelab repository: edit pikvm/ there,
    ${comment} not this file, which the next deploy overwrites.

  '';

  sourceOf =
    f:
    f.binary or (pkgs.writeText (lib.replaceStrings [ "/" ] [ "-" ] (lib.removePrefix "/" f.path)) (
      header (f.comment or "#") + f.text
    ));
in
pkgs.runCommand "pikvm-config" { } (
  ''
    mkdir -p $out/tree
    install -m 0755 ${./apply.sh} $out/apply.sh
    echo ${lib.escapeShellArg (lib.concatLines packages)} > $out/packages
  ''
  + lib.concatMapStrings (f: ''
    install -D -m ${f.mode} ${sourceOf f} $out/tree${f.path}
    echo "${f.mode} ${f.path} ${f.action}" >> $out/manifest
  '') files
)
