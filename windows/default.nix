# The Windows PCs' configuration: what windows/deploy installs and keeps in
# place on each machine in hosts.nix, built as a tree holding apply.ps1, the
# settings it reads, and the HWiNFO exporter. The machines run Windows, so
# packages come from winget at the versions pinned here and apply.ps1 sets up
# what winget does not: services, firewall rules, SSH, network settings and
# HWiNFO's settings.
{
  pkgs,
  hwinfo_exporter,
  sshKeys,
}:

let
  windows = import ./hosts.nix;

  config = {
    # winget packages at pinned versions. A bump here is applied by the next
    # deploy. services and processes name what runs the package's files,
    # stopped while winget replaces them.
    packages = [
      {
        id = "Prometheus.WindowsExporter";
        version = "0.31.8";
        services = [ "windows_exporter" ];
        processes = [ ];
      }
      {
        id = "utkuozdemir.nvidia_gpu_exporter";
        version = "1.15.1";
        services = [ "nvidia_gpu_exporter" ];
        processes = [ ];
      }
      {
        id = "REALiX.HWiNFO";
        version = "8.54";
        services = [ ];
        processes = [ "HWiNFO64" ];
      }
    ];

    # Services apply.ps1 creates where the package does not. The windows
    # exporter's installer registers its own service and firewall rule.
    services = {
      nvidia_gpu_exporter = {
        displayName = "Nvidia GPU Exporter";
        # winget links a portable package's executable here.
        path = ''"C:\Program Files\WinGet\Links\nvidia_gpu_exporter.exe"'';
      };
      hwinfo_exporter = {
        displayName = "hwinfo_exporter";
        path = ''"C:\Program Files\hwinfo_exporter\hwinfo_exporter.exe"'';
      };
    };

    # Inbound firewall rules by display name: the exporter ports, and ping,
    # which Windows otherwise drops.
    firewall = [
      {
        name = "windows_exporter";
        protocol = "TCP";
        port = windows.exporters.windows;
      }
      {
        name = "Nvidia GPU Exporter";
        protocol = "TCP";
        port = windows.exporters.nvidia_gpu;
      }
      {
        name = "hwinfo_exporter";
        protocol = "TCP";
        port = windows.exporters.hwinfo;
      }
      {
        name = "ICMPv4 echo";
        protocol = "ICMPv4";
        icmpType = "8";
      }
      {
        name = "ICMPv6 echo";
        protocol = "ICMPv6";
        icmpType = "128";
      }
    ];

    # The admin's FIDO2 keys, the only ones sshd accepts, as on the machines
    # and the KVM; see nixos/ssh-keys.nix.
    sshKeys = sshKeys.fido;

    # HWiNFO settings, merged into the [Settings] section of its INI file:
    # shared memory on for the exporter, started minimized at logon to the
    # sensors window.
    hwinfo = {
      SensorsSM = 1;
      ShowWelcomeAndProgress = 0;
      Autorun = 1;
      PersistentDriver = 1;
      MinimalizeSensors = 1;
      MinimalizeSensorsClose = 1;
      OpenSensors = 1;
      MinimalizeMainWnd = 1;
    };
  };
in
pkgs.runCommand "windows" { } ''
  mkdir -p $out
  cp ${./apply.ps1} $out/apply.ps1
  cp ${pkgs.writeText "config.json" (builtins.toJSON config)} $out/config.json
  cp ${hwinfo_exporter}/bin/hwinfo_exporter.exe $out/hwinfo_exporter.exe
''
