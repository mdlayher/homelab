# hass

The Home Assistant appliance: a Home Assistant Green on the management LAN
running Home Assistant OS, not NixOS, so this directory builds the
configuration the repository manages on it and `deploy` applies it over
SSH, as root in the Terminal & SSH add-on. Nothing applies it nightly.

- `default.nix`: the managed configuration, built as `.#hass`:
  - `configuration.yaml`, and `alloy/hass.alloy`, the configuration the
    Alloy add-on runs in place of the one its options would generate, with
    Loki's URL filled in from the inventory and checked with
    `alloy validate`;
  - the custom integrations under `custom_components/`, each copied from a
    pinned release of its source and loaded by a restart of core;
  - the custom ZHA quirks under `zha_quirks/`, which
    `zha.custom_quirks_path` names and ZHA loads at a restart of core;
    see [Power outage memory](#power-outage-memory);
  - the options of each managed add-on, `addons/<slug>.json`, posted to
    the Supervisor; options left out keep the add-on's defaults and are not
    compared. The Terminal & SSH add-on takes the admin's FIDO2 keys from
    `nixos/ssh-keys.nix`, so every login takes a YubiKey touch; the others
    hold what was set on the appliance, so a change made there shows up as
    drift.
- `apply.sh`: runs on the appliance; installs what differs, checks the
  configuration with `ha core check` before restarting core, and restarts
  each add-on whose options or files changed. A configuration the check
  rejects is put back as it was.
- `deploy`: builds and applies over SSH. It sends each deploy's provenance
  to Loki itself, under `{unit="deploy"}`, and a finished one is announced
  in the Discord ops channel; see lib/deploy.sh.

```sh
# Show how the appliance differs from this checkout; changes nothing.
hass/deploy --check

# Apply.
hass/deploy
```

A deploy may restart core (the UI and automations stop for a minute or
so), and the add-ons whose options changed. The deploy's connection runs
through the Terminal & SSH and Tailscale add-ons, so they restart a few
seconds after the deploy has finished.

## Power outage memory

The Aqara smart plugs (`lumi.plug.maus01`) must restore their relay state
after a utility outage. ZHA exposes no entity for the setting, so
`zha_quirks/aqara_plug_outage_memory.py` extends the upstream quirk with
the manufacturer-specific Basic attribute the plug takes it through,
0xFFF0, keeping every other cluster as upstream has it. The setting is
write-only; set it once per plug, from Developer tools → Actions:

```yaml
action: zha.set_zigbee_cluster_attribute
data:
  ieee: "<plug IEEE>"
  endpoint_id: 1
  cluster_id: 0
  attribute: 65520
  manufacturer: 4447
  # On; "aa 80 05 d1 47 01 01 10 00" turns it off.
  value: "aa 80 05 d1 47 00 01 10 01"
```

The payloads are zigbee2mqtt's `lumi_switch_power_outage_memory` in
zigbee-herdsman-converters `src/lib/lumi.ts`.

## Not managed here

- `automations.yaml`, `groups.yaml`, `scripts.yaml`, `scenes.yaml` and
  `blueprints/`, which `configuration.yaml` includes: the UI writes them.
- `.storage/`: the UI's own state, integrations, the registries of floors,
  areas, devices and entities, and users.
- `secrets.yaml` on the appliance.
- Add-ons not in `default.nix`, and which add-ons are installed.
- The Tailscale add-on's node state and tags.

## Adding an add-on

1. Read its options without a touch, over the websocket:
   `hassq ws '{"type":"supervisor/api","endpoint":"/addons/<slug>/info","method":"get"}'`.
2. Add them under `addons` in `default.nix`, with `restart = "later"` if the
   deploy's connection runs through it.
3. `hass/deploy --check` reports no drift for it.
