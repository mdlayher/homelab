# The Windows PCs' configuration: what windows/deploy installs and keeps in
# place on each machine in hosts.nix, built as a tree holding apply.ps1, the
# settings it reads, and the HWiNFO exporter. The machines run Windows, so
# packages come from winget at the versions pinned here and apply.ps1 sets up
# what winget does not: services, firewall rules, SSH, network and time
# settings, configuration files, and HWiNFO's settings.
{
  lib,
  pkgs,
  hwinfo_exporter,
  inventory,
  sshKeys,
  # Loki's port on the server, from its configuration.
  lokiPort,
}:

let
  windows = import ./hosts.nix;

  # The Windows event log channels Alloy ships, by the component name each
  # gets in its configuration.
  channels = {
    application = "Application";
    system = "System";
    openssh = "OpenSSH/Operational";
  };

  # Alloy's configuration: the event log to Loki on the server by its service
  # name, labeled with the machine and channel. Bookmarks keep each channel's
  # place across restarts in Alloy's data directory.
  alloyConfig = pkgs.writeText "config.alloy" (
    ''
      // Managed by windows/deploy from the homelab repository: edit windows/ there.
      loki.write "server" {
        endpoint {
          url = "http://loki.svc.${inventory.zone}:${toString lokiPort}/loki/api/v1/push"
        }
      }

      loki.process "eventlog" {
        forward_to = [loki.write.server.receiver]

        stage.static_labels {
          values = {
            host = string.to_lower(sys.env("COMPUTERNAME")),
            job  = "windows-eventlog",
          }
        }
      }
    ''
    + lib.concatStrings (
      lib.mapAttrsToList (name: channel: ''

        loki.source.windowsevent "${name}" {
          eventlog_name          = "${channel}"
          use_incoming_timestamp = true
          bookmark_path          = "C:/ProgramData/GrafanaLabs/Alloy/data/bookmark-${name}.xml"
          labels                 = { channel = "${channel}" }
          forward_to             = [loki.process.eventlog.receiver]
        }
      '') channels
    )
    + ''

      // Steam's record of the game processes it starts and stops, from the
      // lines naming an app: "AppID <id> adding PID <pid> as a tracked
      // process <command line>", "AppID <id> no longer tracking PID <pid>,
      // exit code <n>" and "Remove <id> from running list". A machine
      // without Steam matches no file. The lines carry the local time.
      local.file_match "steam" {
        path_targets = [{"__path__" = "C:/Program Files (x86)/Steam/logs/gameprocess_log.txt"}]
      }

      loki.source.file "steam" {
        targets       = local.file_match.steam.targets
        tail_from_end = true
        forward_to    = [loki.process.steam.receiver]
      }

      loki.process "steam" {
        forward_to = [loki.write.server.receiver]

        stage.static_labels {
          values = {
            host = string.to_lower(sys.env("COMPUTERNAME")),
            job  = "steam",
          }
        }

        stage.match {
          selector = "{job=\"steam\"} !~ \"^\\\\[[^]]+\\\\] (AppID|Remove) [0-9]+ \""
          action   = "drop"
        }

        stage.regex {
          expression = "^\\[(?P<time>[^]]+)\\] "
        }

        stage.timestamp {
          source   = "time"
          format   = "2006-01-02 15:04:05"
          location = "Local"
        }
      }
    ''
  );

  # windows_exporter's configuration: its default collectors, time for the
  # clock's offset from its NTP source, diskdrive for each drive's status,
  # tcp, update for pending Windows updates, and scheduled_task for HWiNFO's
  # logon task alone.
  windowsExporterConfig = pkgs.writeText "config.yaml" ''
    # Managed by windows/deploy from the homelab repository: edit windows/ there.
    collectors:
      enabled: cpu,diskdrive,logical_disk,memory,net,os,physical_disk,scheduled_task,service,system,tcp,time,update
    collector:
      scheduled_task:
        include: "/HWiNFO"
  '';

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
        id = "GrafanaLabs.Alloy";
        version = "1.20.1";
        services = [ "Alloy" ];
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
        name = "Alloy";
        protocol = "TCP";
        port = windows.exporters.alloy;
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

    # Configuration files from this tree, each replaced when it differs and
    # its service restarted.
    files = [
      {
        source = "windows_exporter.yaml";
        path = ''C:\Program Files\windows_exporter\config.yaml'';
        service = "windows_exporter";
      }
      {
        source = "config.alloy";
        path = ''C:\Program Files\GrafanaLabs\Alloy\config.alloy'';
        service = "Alloy";
      }
    ];

    # The arguments Alloy's service runs with, kept in the registry: the
    # installer's own, and its HTTP server on every address for Prometheus.
    alloyArguments = [
      "run"
      ''C:\Program Files\GrafanaLabs\Alloy\config.alloy''
      ''--storage.path=C:\ProgramData\GrafanaLabs\Alloy\data''
      "--server.http.listen-addr=0.0.0.0:${toString windows.exporters.alloy}"
    ];

    # The anycast NTP address, served at every site; see nixos/inventory/.
    ntp = inventory.anycast4.ntp;

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
  cp ${alloyConfig} $out/config.alloy
  cp ${windowsExporterConfig} $out/windows_exporter.yaml
''
