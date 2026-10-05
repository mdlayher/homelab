# The serial consoles each machine can open, derived from the console lines
# in ./physical.nix, keyed by that machine and then by console name.
#
# A console is named for the role its machine holds, or for the machine
# when it holds none, so a hardware swap keeps the name. A port on a card
# belongs to the machine the card is fitted in. A line ending on a
# multi-port adapter belongs to the machine on the adapter's upstream port
# and selects the port by interface number, the label minus one. A USB
# serial cable belongs to the machine it plugs into, and any other line to
# the machine whose port it ends on.
{ lib, inventory }:

let
  inherit (inventory.physical) devices;
  cables = lib.concatLists (lib.attrValues inventory.physical.cables);

  # The machine a device is, or is fitted in.
  machineOf =
    device:
    let
      d = devices.${device} or { };
    in
    if d ? fittedIn then machineOf d.fittedIn.device else device;

  nameOf =
    machine:
    lib.findFirst (role: lib.elem machine inventory.roles.${role}) machine (
      lib.attrNames inventory.roles
    );

  # The machine at the far end of the cable on a device's port.
  peerOf =
    end:
    let
      c = lib.findFirst (
        c: c.src == end || c.dst == end
      ) (throw "nothing is cabled to ${end.device} ${end.port}") cables;
    in
    machineOf (if c.src == end then c.dst else c.src).device;

  console =
    c:
    let
      end = c.src;
      adapter = devices.${end.device} or { };
      inherit (c.console) baud;
    in
    if adapter ? upstream then
      {
        opener = peerOf {
          inherit (end) device;
          port = adapter.upstream;
        };
        spec = {
          serial =
            if adapter.serial != null then
              adapter.serial
            else
              throw "${end.device} has no serial; read it from consrv's startup log";
          interface = lib.toInt end.port - 1;
          inherit baud;
        };
      }
    else if c ? serial then
      {
        opener = machineOf end.device;
        spec = {
          inherit (c) serial;
          inherit baud;
        };
      }
    else
      {
        opener = machineOf end.device;
        spec = {
          inherit (end) port;
          inherit baud;
        };
      };

  lines = map (c: console c // { name = nameOf (machineOf c.dst.device); }) (
    lib.filter (c: c ? console) cables
  );
in
lib.mapAttrs (_: ls: lib.listToAttrs (map (l: lib.nameValuePair l.name l.spec) ls)) (
  lib.groupBy (l: l.opener) lines
)
