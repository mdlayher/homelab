# Fails when terraform/unifi/ports.json and the inventory's network cables
# disagree: a port in use without a cable, a cable on a port not in use or
# disabled, or a port's host or trunk naming another device than the
# cable's far end. ports.json must cover exactly the hosts tagged switch.
{
  pkgs,
  lib,
  inventory,
}:

let
  ports = lib.importJSON ../../../terraform/unifi/ports.json;
  switches = import ../../inventory/tagged.nix "switch";

  # Each cable end with its far-end device.
  ends = lib.concatMap (c: [
    {
      inherit (c.src) device port;
      far = c.dst.device;
    }
    {
      inherit (c.dst) device port;
      far = c.src.device;
    }
  ]) inventory.physical.cables.network;
  switchEnds = lib.filter (e: ports ? ${e.device}) ends;
  cabled = sw: port: lib.any (e: e.device == sw && e.port == port) switchEnds;

  # A switch's in-use ports to the device each names, or null.
  inUse =
    sw:
    lib.mapAttrs (_: p: p.host or null) ports.${sw}.manual
    // lib.mapAttrs (_: device: device) ports.${sw}.trunks;

  uncabled = lib.concatMap (
    sw:
    map (port: "${sw} port ${port}: in use in tofu, no cable in the inventory") (
      lib.filter (port: !(cabled sw port)) (lib.attrNames (inUse sw))
    )
  ) (lib.attrNames ports);

  unconfigured = lib.concatMap (
    e:
    let
      inherit (ports.${e.device}) disabled;
    in
    lib.optional (
      !(inUse e.device ? ${e.port})
    ) "${e.device} port ${e.port}: cabled to ${e.far} in the inventory, not in use in tofu"
    ++ lib.optional (lib.elem e.port (map toString disabled)) "${e.device} port ${e.port}: cabled to ${e.far} in the inventory, disabled in tofu"
  ) switchEnds;

  mismatched = lib.concatMap (
    e:
    let
      named = (inUse e.device).${e.port} or null;
    in
    lib.optional (
      named != null && named != e.far
    ) "${e.device} port ${e.port}: tofu names ${named}, the inventory cables ${e.far}"
  ) switchEnds;

  untracked =
    map (sw: "${sw}: an inventory switch missing from ports.json") (
      lib.subtractLists (lib.attrNames ports) switches
    )
    ++ map (sw: "${sw}: in ports.json but no inventory switch") (
      lib.subtractLists switches (lib.attrNames ports)
    );

  errors = untracked ++ uncabled ++ unconfigured ++ mismatched;
in
pkgs.runCommand "unifi-cabling" { } (
  if errors == [ ] then
    "touch $out"
  else
    ''
      cat <<'EOF'
      ${lib.concatStringsSep "\n" errors}
      EOF
      exit 1
    ''
)
