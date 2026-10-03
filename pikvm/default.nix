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
  tailscalePort = (lib.findFirst (f: f.host == "pikvm") null inventory.tailscaleForwards).port;

  # Packages the managed files belong to, installed by hand (see README.md);
  # apply.sh refuses to change anything while one is missing.
  packages = [
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

  # Every text file opens with this, in the comment syntax all of them
  # share, so an edit made on the device is recognizable as one the next
  # deploy overwrites.
  header = ''
    # Managed by pikvm/deploy from the homelab repository: edit pikvm/ there,
    # not this file, which the next deploy overwrites.

  '';

  sourceOf =
    f:
    f.binary or (pkgs.writeText (lib.replaceStrings [ "/" ] [ "-" ] (lib.removePrefix "/" f.path)) (
      header + f.text
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
