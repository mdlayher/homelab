# The CyberPower cards' configuration: the SNMP objects this repository
# manages on the network management card of each PDU and UPS, built as one
# file per card of `<oid> <type> <value>` lines for cyberpower/deploy to
# compare and set with net-snmp. The objects rendered here are the whole
# of what the deploy may write.
{
  lib,
  pkgs,
  # The server's inventory, for each card's name.
  inventory,
}:

let
  kinds = import ./hosts.nix;
  inherit (kinds) hosts;

  # A row of a card's desired state as { name, oid, type, value }: object
  # is a column of table, under the subtree at base, and index its instance.
  mkRow =
    base: table: object: index: value:
    let
      column = lib.splitString " " table.${object};
    in
    {
      name = "${object}.${toString index}";
      oid = "${base}.${lib.elemAt column 0}.${toString index}";
      type = lib.elemAt column 1;
      inherit value;
    };

  # The managed objects of the ePDU2 subtree, by MIB name: the column under
  # ePDU2, then the type net-snmp sets it as, s for a string, i for an
  # integer. Taken from CyberPower_MIB_v2.13. A row is the column followed
  # by its index: the module for the device, the bank, phase or outlet
  # number otherwise.
  ePDU2 = "1.3.6.1.4.1.3808.1.1.6";
  pduObjects = {
    ePDU2DeviceConfigLocation = "3.2.1.4 s";
    ePDU2DeviceConfigContact = "3.2.1.5 s";
    ePDU2DeviceConfigColdstartDelay = "3.2.1.7 i";
    ePDU2DeviceConfigCurrentLowLoadThreshold = "3.2.1.8 i";
    ePDU2DeviceConfigCurrentNearOverloadThreshold = "3.2.1.9 i";
    ePDU2DeviceConfigCurrentOverloadThreshold = "3.2.1.10 i";
    ePDU2PhaseConfigLowLoadThreshold = "4.2.1.5 i";
    ePDU2PhaseConfigNearOverloadThreshold = "4.2.1.6 i";
    ePDU2PhaseConfigOverloadThreshold = "4.2.1.7 i";
    ePDU2BankConfigLowLoadThreshold = "5.2.1.5 i";
    ePDU2BankConfigNearOverloadThreshold = "5.2.1.6 i";
    ePDU2BankConfigOverloadThreshold = "5.2.1.7 i";
    ePDU2OutletSwitchedConfigName = "6.1.2.1.4 s";
    ePDU2OutletSwitchedConfigPowerOnTime = "6.1.2.1.5 i";
    ePDU2OutletSwitchedConfigPowerOffTime = "6.1.2.1.6 i";
    ePDU2OutletSwitchedConfigRebootDuration = "6.1.2.1.7 i";
    ePDU2OutletMeteredConfigName = "6.2.2.1.4 s";
    ePDU2OutletMeteredConfigLowLoadThreshold = "6.2.2.1.5 i";
    ePDU2OutletMeteredConfigNearOverloadThreshold = "6.2.2.1.6 i";
    ePDU2OutletMeteredConfigOverloadThreshold = "6.2.2.1.7 i";
  };

  # Current thresholds in amps, for the device, each bank and each phase.
  amps = {
    low = 0;
    nearOverload = 9;
    overload = 12;
  };

  # What every PDU is set to, under its own overrides in pdus below. Outlet
  # times are in seconds; metered thresholds, on a PDU with metered
  # outlets, in watts.
  pduDefaults = {
    module = 1;
    banks = 1;
    phases = 1;
    metered = false;
    location = "server-rack";
    contact = "mdlayher";
    coldstartDelay = 0;
    current = amps;
    bankCurrent = amps;
    phaseCurrent = amps;
    meteredThresholds = {
      low = 0;
      nearOverload = 1080;
      overload = 1440;
    };
    # By outlet number. An outlet's name is written to both its switched
    # and, on a metered PDU, its metered name.
    outlets = lib.genAttrs (map toString (lib.range 1 8)) (n: {
      name = "Outlet${n}";
      powerOnTime = 3;
      powerOffTime = 3;
      rebootDuration = 5;
    });
  };

  # Each PDU's overrides of pduDefaults, merged attribute by attribute, so
  # outlets."3".name = "..." renames one outlet and keeps its times.
  pdus = {
    pdu01 = { };
    pdu02.metered = true;
  };

  # The rows of one PDU.
  pduRows =
    pdu:
    let
      row = mkRow ePDU2 pduObjects;
      thresholds = prefix: index: t: [
        (row "${prefix}LowLoadThreshold" index t.low)
        (row "${prefix}NearOverloadThreshold" index t.nearOverload)
        (row "${prefix}OverloadThreshold" index t.overload)
      ];
      outlet =
        n: o:
        [
          (row "ePDU2OutletSwitchedConfigName" n o.name)
          (row "ePDU2OutletSwitchedConfigPowerOnTime" n o.powerOnTime)
          (row "ePDU2OutletSwitchedConfigPowerOffTime" n o.powerOffTime)
          (row "ePDU2OutletSwitchedConfigRebootDuration" n o.rebootDuration)
        ]
        ++ lib.optionals pdu.metered (
          [ (row "ePDU2OutletMeteredConfigName" n o.name) ]
          ++ thresholds "ePDU2OutletMeteredConfig" n pdu.meteredThresholds
        );
    in
    [
      (row "ePDU2DeviceConfigLocation" pdu.module pdu.location)
      (row "ePDU2DeviceConfigContact" pdu.module pdu.contact)
      (row "ePDU2DeviceConfigColdstartDelay" pdu.module pdu.coldstartDelay)
    ]
    ++ thresholds "ePDU2DeviceConfigCurrent" pdu.module pdu.current
    ++ lib.concatMap (b: thresholds "ePDU2BankConfig" b pdu.bankCurrent) (lib.range 1 pdu.banks)
    ++ lib.concatMap (p: thresholds "ePDU2PhaseConfig" p pdu.phaseCurrent) (lib.range 1 pdu.phases)
    ++ lib.concatLists (lib.mapAttrsToList outlet pdu.outlets);

  # The managed objects of the ups subtree, as pduObjects is for ePDU2.
  # Each is a scalar, instance 0. Taken from CyberPower_MIB_v2.13.
  upsTree = "1.3.6.1.4.1.3808.1.1.1";
  upsObjects = {
    upsAdvanceConfigOutputVoltage = "5.2.1 i";
    upsAdvanceConfigAlarm = "5.2.4 i";
    upsAdvanceConfigColdStart = "5.2.15 i";
    upsAdvanceConfigDeepDischargeProtection = "5.2.16 i";
    upsAdvanceConfigSleepAfterAllClientShut = "5.2.17 i";
    upsAdvanceConfigLowBatteryThreshold = "5.2.18 i";
  };

  # The integer each enumerated object in upsObjects takes for a name, from
  # the same MIB.
  upsEnums = {
    upsAdvanceConfigAlarm = {
      timed = 1;
      enable = 2;
      disable = 3;
      mute = 4;
    };
    upsAdvanceConfigColdStart = {
      disable = 1;
      enable = 2;
    };
    upsAdvanceConfigSleepAfterAllClientShut = {
      disable = 1;
      enable = 2;
    };
  };

  # What every UPS is set to, under its own overrides in upses below. The
  # output voltage is in VAC, one of 100 110 120 127 208 220 230 240; deep
  # discharge protection in minutes, one of 0 20 40 60; the low battery
  # threshold in percent. Enumerated objects take a name from upsEnums.
  upsDefaults = {
    outputVoltage = 120;
    alarm = "disable";
    coldStart = "enable";
    deepDischargeProtection = 0;
    sleepAfterAllClientShut = "disable";
    lowBatteryThreshold = 10;
  };

  # Each UPS's overrides of upsDefaults.
  upses = {
    ups01 = { };
  };

  # The rows of one UPS, an enumerated object's name mapped to its integer.
  upsRows =
    ups:
    let
      enum =
        object: value:
        assert lib.assertMsg (upsEnums.${object} ? ${toString value})
          "cyberpower: ${object} has no value ${toString value}; it takes one of ${
            lib.concatStringsSep " " (lib.attrNames upsEnums.${object})
          }";
        upsEnums.${object}.${value};
      row =
        object: value:
        mkRow upsTree upsObjects object 0 (if upsEnums ? ${object} then enum object value else value);
    in
    [
      (row "upsAdvanceConfigOutputVoltage" ups.outputVoltage)
      (row "upsAdvanceConfigAlarm" ups.alarm)
      (row "upsAdvanceConfigColdStart" ups.coldStart)
      (row "upsAdvanceConfigDeepDischargeProtection" ups.deepDischargeProtection)
      (row "upsAdvanceConfigSleepAfterAllClientShut" ups.sleepAfterAllClientShut)
      (row "upsAdvanceConfigLowBatteryThreshold" ups.lowBatteryThreshold)
    ];

  # Every card's rows, checked to read back as written: the deploy reads a
  # value to the end of its line, with whitespace around it trimmed, and
  # compares a string as net-snmp prints it, unescaped.
  checked =
    name: rows:
    map (
      r:
      assert lib.assertMsg
        (
          if r.type == "s" then
            lib.isString r.value && builtins.match ".*[\n\"\\].*" r.value == null && lib.trim r.value == r.value
          else
            lib.isInt r.value
        )
        "cyberpower: ${name} ${r.name} has the wrong type, a newline, quote or backslash, or surrounding whitespace";
      r
    ) rows;
  hostRows =
    lib.genAttrs kinds.pdus (
      name: checked name (pduRows (lib.recursiveUpdate pduDefaults pdus.${name}))
    )
    // lib.genAttrs kinds.upses (
      name: checked name (upsRows (lib.recursiveUpdate upsDefaults upses.${name}))
    );

  # The name of each OID, for the deploy's report.
  names = lib.concatStrings (
    lib.unique (lib.concatMap (map (r: "${r.oid} ${r.name}\n")) (lib.attrValues hostRows))
  );

  # Each card's SNMP agent as net-snmp addresses it. The cards answer on
  # IPv4 alone, so each is reached by its IPv4 name.
  targets = lib.concatMapStrings (
    name: "${name} udp:ipv4.${inventory.hosts.${name}.dnsName}.${inventory.domain}:161\n"
  ) hosts;
in
assert lib.assertMsg (
  lib.attrNames pdus == kinds.pdus
) "cyberpower: pdus in default.nix must be the PDUs in hosts.nix";
assert lib.assertMsg (
  lib.attrNames upses == kinds.upses
) "cyberpower: upses in default.nix must be the UPSes in hosts.nix";
pkgs.runCommand "cyberpower-config" { } (
  ''
    mkdir $out
    install -m 0644 ${pkgs.replaceVars ./apply.sh { netSnmp = lib.getBin pkgs.net-snmp; }} $out/apply.sh
    cp ${pkgs.writeText "names" names} $out/names
    cp ${pkgs.writeText "targets" targets} $out/targets
  ''
  + lib.concatMapStrings (name: ''
    cp ${
      pkgs.writeText name (
        lib.concatMapStrings (r: "${r.oid} ${r.type} ${toString r.value}\n") hostRows.${name}
      )
    } $out/${name}
  '') hosts
)
