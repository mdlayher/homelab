# The CyberPower PDUs' configuration: the SNMP objects this repository
# manages on each PDU's management card, built as one file per PDU of
# `<oid> <type> <value>` lines for cyberpower/deploy to compare and set
# with net-snmp. The objects rendered here are the whole of what the
# deploy may write.
{
  lib,
  pkgs,
  # The server's inventory, for each PDU's name.
  inventory,
}:

let
  inherit (import ./hosts.nix) hosts;

  # The managed objects of the ePDU2 subtree, by MIB name: the column under
  # ePDU2, then the type net-snmp sets it as, s for a string, i for an
  # integer. Taken from CyberPower_MIB_v2.13. A row is the column followed
  # by its index: the module for the device, the bank, phase or outlet
  # number otherwise.
  ePDU2 = "1.3.6.1.4.1.3808.1.1.6";
  objects = {
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
  defaults = {
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

  # Each PDU's overrides of defaults, merged attribute by attribute, so
  # outlets."3".name = "..." renames one outlet and keeps its times.
  pdus = {
    pdu01 = { };
    pdu02.metered = true;
  };

  # The rows of one PDU as { name, oid, type, value }.
  rows =
    pdu:
    let
      row =
        object: index: value:
        let
          column = lib.splitString " " objects.${object};
        in
        {
          name = "${object}.${toString index}";
          oid = "${ePDU2}.${lib.elemAt column 0}.${toString index}";
          type = lib.elemAt column 1;
          inherit value;
        };
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

  # Every PDU's rows, checked to read back as written: the deploy reads a
  # value to the end of its line, with whitespace around it trimmed, and
  # compares a string as net-snmp prints it, unescaped.
  pduRows = lib.genAttrs hosts (
    name:
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
    ) (rows (lib.recursiveUpdate defaults pdus.${name}))
  );

  # The name of each OID, for the deploy's report.
  names = lib.concatStrings (
    lib.unique (lib.concatMap (map (r: "${r.oid} ${r.name}\n")) (lib.attrValues pduRows))
  );

  # Each card's SNMP agent as net-snmp addresses it. The cards answer on
  # IPv4 alone, so each is reached by its IPv4 name.
  targets = lib.concatMapStrings (
    name: "${name} udp:ipv4.${inventory.hosts.${name}.dnsName}.${inventory.domain}:161\n"
  ) hosts;
in
assert lib.assertMsg (
  lib.attrNames pdus == hosts
) "cyberpower: pdus in default.nix must be the hosts in hosts.nix";
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
        lib.concatMapStrings (r: "${r.oid} ${r.type} ${toString r.value}\n") pduRows.${name}
      )
    } $out/${name}
  '') hosts
)
