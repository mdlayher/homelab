# cyberpower

The CyberPower PDUs listed in `hosts.nix`, managed through the SNMP agent
on each PDU's network management card. The cards are not NixOS, so this
directory builds the SNMP objects the repository manages on them and
`deploy` sets them over SNMPv3. Nothing applies it nightly.

- `hosts.nix`: the PDUs, the inventory hosts tagged `pdu`.
- `default.nix`: the managed objects, built as `.#cyberpower`: per outlet
  its name and power-on, power-off and reboot times; per device its
  location, contact, cold-start delay and current thresholds; the current
  thresholds of each bank and phase; and on a PDU with metered outlets,
  each outlet's power thresholds. Shared defaults sit under each PDU's
  overrides. The OID table names the MIB version it was taken from.
  The build is one file per PDU of `<oid> <type> <value>` lines, beside
  the name of each OID, each card's SNMP address and `apply.sh`.
- `apply.sh`: runs through the gate, as the gate's user, with the SNMPv3
  credentials in its environment; reads every managed object of a PDU and
  prints each difference as `<object> <current> -> <desired>`. A deploy
  sets the differences in one request and reads them back, failing if any
  did not take. It reads only the built tree.
- `deploy`: builds, then runs `apply.sh` for every host in one gate call.
  It sends each deploy's provenance to Loki itself, under
  `{unit="deploy"}`, and a finished one is announced in the Discord ops
  channel; see lib/deploy.sh.

The SNMPv3 user's credentials live in `secrets/cyberpower.yaml`, readable
by the admin and the gate alone. `deploy` hands them to `apply.sh` with
`sops-gate exec-env secrets/cyberpower.yaml`, so every run is a touch:

```sh
# Show how the PDUs differ from this checkout; changes nothing.
cyberpower/deploy --check --all

# Apply.
cyberpower/deploy --all
```

The cards answer SNMPv1 reads from the server alone, and the v3 user is
pinned to the development container's address, so a check needs the v3
credentials as a deploy does: each run is a YubiKey touch, which is the
gate on writing to a PDU. The cards answer SNMP on IPv4 alone, so `deploy`
reaches each by its inventory IPv4 name; the router admits the container
to them on UDP 161.

## Not managed here

- Switching outlets on, off or rebooting them, and resetting peak load or
  energy counters: `deploy` writes only the objects `default.nix` renders,
  never a command or reset object, so switching an outlet stays a manual
  act on the card.
- The device name, which is the inventory name and set by hand.
- The card's network, SNMP, syslog, user and firmware settings, and the
  UPS's card, which carries the `cyberpower` tag but not `pdu`.
