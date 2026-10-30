# The Home Assistant appliance's configuration: the files and add-on options
# this repository manages on it, built as a tree with manifests for
# hass/deploy to apply. The appliance runs Home Assistant OS rather than
# NixOS, so the configuration is rendered here and applied over SSH through
# the Terminal & SSH add-on.
{
  lib,
  pkgs,
  inventory,
  sshKeys,
  # Loki's port on the server, from its configuration.
  lokiPort,
}:

let
  # Loads that run for seconds at a time, which a scrape at any interval
  # misses: a template binary sensor turns each plug's power reading into
  # running or not, and an automation counts every start into a counter,
  # which the prometheus integration exports as homeassistant_counter_value.
  # The key is the plug's entity stem; event names the counter. threshold
  # is the power in watts above which the plug counts as running, for a
  # load whose motor draws less than the default. delayOff holds the
  # sensor on across the pauses within one event.
  pulses = {
    kitchen_coffee_grinder = {
      name = "Kitchen Coffee Grinder";
      event = "Runs";
    };
    storage_sump_pump = {
      name = "Storage Sump Pump";
      event = "Runs";
    };
    # A regeneration is a series of backwash, brine and rinse stages: the
    # valve motor draws a few watts for seconds to advance each stage and
    # the controller about a watt between them.
    storage_water_softener = {
      name = "Storage Water Softener";
      event = "Regenerations";
      threshold = 2;
      delayOff = "00:10:00";
    };
  };

  # Shifts a rendered block right by n columns, since an indented string
  # drops the common leading whitespace that places it in the file.
  indent =
    n: s:
    lib.concatStringsSep "\n" (
      map (l: if l == "" then l else lib.strings.replicate n " " + l) (lib.splitString "\n" s)
    );

  pulseSensors = lib.concatStrings (
    lib.mapAttrsToList (
      stem: p:
      ''
        - name: "${p.name} Running"
          unique_id: ${stem}_running
          state: "{{ states('sensor.${stem}_plug_power') | float(0) > ${toString (p.threshold or 5)} }}"
      ''
      + lib.optionalString (p ? delayOff) "  delay_off: \"${p.delayOff}\"\n"
    ) pulses
  );

  pulseCounters = lib.concatStrings (
    lib.mapAttrsToList (stem: p: ''
      ${stem}_${lib.toLower p.event}:
        name: "${p.name} ${p.event}"
        step: 1
    '') pulses
  );

  pulseAutomations = lib.concatStrings (
    lib.mapAttrsToList (stem: p: ''
      - id: ${stem}_${lib.toLower p.event}
        alias: "${p.name} ${p.event}"
        triggers:
          - trigger: state
            entity_id: binary_sensor.${stem}_running
            from: "off"
            to: "on"
        actions:
          - action: counter.increment
            target:
              entity_id: counter.${stem}_${lib.toLower p.event}
    '') pulses
  );

  configuration = ''

    # Configure a default setup of Home Assistant (frontend, api, etc)
    default_config:

    # Text to speech
    tts:
      - platform: google_translate

    group: !include groups.yaml
    automation: !include automations.yaml
    script: !include scripts.yaml
    scene: !include scenes.yaml

    prometheus:

    template:
      - binary_sensor:
    ${indent 6 pulseSensors}
    counter:
    ${indent 2 pulseCounters}
    automation managed:
    ${indent 2 pulseAutomations}'';

  # Each managed add-on's options, posted to the Supervisor, which keeps the
  # add-on's defaults for any left out; only the options declared here are
  # compared. restart is "now", or "later" for an add-on the deploy's own
  # connection runs through, which apply.sh restarts only after the deploy
  # has finished.
  addons = {
    core_ssh = {
      restart = "later";
      options = {
        # The admin's FIDO2 keys alone, so every login needs a physical
        # YubiKey touch. The add-on has no option to narrow a key to some
        # sources.
        authorized_keys = sshKeys.fido;
        password = "";
        apks = [ ];
        server.tcp_forwarding = false;
      };
    };

    a0d7b954_tailscale = {
      restart = "later";
      options = {
        accept_dns = true;
        accept_routes = false;
        advertise_connector = false;
        advertise_exit_node = false;
        advertise_routes = [ ];
        advertise_tags = [ ];
        always_use_derp = false;
        log_suppression = true;
        log_upload = true;
        login_server = "https://controlplane.tailscale.com";
        share_homeassistant = "disabled";
        share_on_port = "443";
        services = [ ];
        snat_subnet_routes = true;
        stateful_filtering = false;
        taildrive = {
          local_apps = false;
          app_configs = false;
          backup = false;
          config = false;
          media = false;
          share = false;
          ssl = false;
        };
        taildrop = false;
        userspace_networking = false;
      };
    };

    # With override_config set the add-on runs the file at
    # override_config_path, managed under files below, and ignores the
    # options that would otherwise generate its configuration.
    # environment_variables still reaches the file through sys.env(). The
    # Supervisor requires the generator's switches and basic-auth fields
    # all the same, so they are present, off and empty.
    "6b3a3951_grafana_alloy" = {
      restart = "now";
      options = {
        override_config = true;
        override_config_path = "/config/alloy/hass.alloy";
        environment_variables = [ ];
        enable_prometheus = false;
        enable_unix_component = false;
        enable_process_component = false;
        prometheus_scrape_interval = "15s";
        prometheus_basic_auth = {
          username = "";
          password = "";
        };
        enable_loki = false;
        enable_loki_syslog = false;
        loki_basic_auth = {
          username = "";
          password = "";
        };
      };
    };

    "1ee57b99_node_exporter" = {
      restart = "now";
      options = {
        enable_basic_auth = false;
        basic_auth_user = "";
        basic_auth_pass = "";
        enable_tls = false;
        cert_file = "";
        cert_key = "";
        cmdline_extra_args = "";
      };
    };

    core_matter_server = {
      restart = "now";
      options = {
        log_level = "info";
        beta = false;
        enable_test_net_dcl = false;
        time_sync = "auto";
      };
    };
  };

  # Custom integrations installed under /config/custom_components, each a
  # directory copied from a pinned source and loaded by a restart of core.
  # A file the source drops in a later version stays on the appliance.
  customComponents = {
    # Open Green Button: utility usage from Green Button Connect My Data
    # into the Energy dashboard's statistics, through the project's hosted
    # OAuth proxy. Consumers Energy is among its live utilities.
    greenbutton = "${
      pkgs.fetchFromGitHub {
        owner = "rocketraman";
        repo = "open-green-button-homeassistant";
        tag = "0.3.3";
        hash = "sha256-bwMbjbKZKBlKskJdgDjpemTCV4TLodGNYTEaLfnG3p4=";
      }
    }/custom_components/greenbutton";
  };

  # The files under /config this repository manages, and what applying a
  # change to each takes: "core" for Home Assistant's own configuration,
  # checked and then loaded by a restart of core, or the slug of the add-on
  # that reads the file, which restarts.
  files = {
    "configuration.yaml" = {
      source = pkgs.writeText "configuration.yaml" configuration;
      action = "core";
    };
    # The configuration the Alloy add-on runs, named by its
    # override_config_path option above.
    "alloy/hass.alloy" = {
      source = pkgs.writeText "hass.alloy" (
        lib.replaceStrings
          [ "@lokiUrl@" ]
          [ "http://loki.svc.${inventory.zone}:${toString lokiPort}/loki/api/v1/push" ]
          (builtins.readFile ./alloy/hass.alloy)
      );
      action = "6b3a3951_grafana_alloy";
    };
  };
in
pkgs.runCommand "hass-config" { } (
  ''
    mkdir -p $out/tree/addons
    install -m 0755 ${./apply.sh} $out/apply.sh
    touch $out/files $out/addons
  ''
  + lib.concatStrings (
    lib.mapAttrsToList (path: f: ''
      install -D -m 0644 ${f.source} $out/tree/${path}
      echo ${lib.escapeShellArg "${path} ${f.action}"} >> $out/files
    '') files
  )
  + lib.concatStrings (
    lib.mapAttrsToList (domain: src: ''
      mkdir -p $out/tree/custom_components
      cp -r ${src} $out/tree/custom_components/${domain}
      chmod -R u+w $out/tree/custom_components/${domain}
      (cd $out/tree && find custom_components/${domain} -type f | sort | sed 's/$/ core/') >> $out/files
    '') customComponents
  )
  # Alloy reads its configuration as a string at start, so nothing else
  # checks it before the add-on fails to load it.
  + ''
    ${pkgs.grafana-alloy}/bin/alloy validate $out/tree/alloy/hass.alloy
  ''
  + lib.concatStrings (
    lib.mapAttrsToList (slug: a: ''
      install -m 0644 ${pkgs.writeText "${slug}.json" (builtins.toJSON a.options)} $out/tree/addons/${slug}.json
      echo ${lib.escapeShellArg "${slug} ${a.restart}"} >> $out/addons
    '') addons
  )
)
