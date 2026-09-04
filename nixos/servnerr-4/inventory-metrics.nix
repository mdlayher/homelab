# Publishes the network inventory to Prometheus as an info metric, so that
# series which carry only an address can be joined to the name of the device
# holding it.
#
# The accounting sets in the router's nftables.nix are the motivating case:
# they give a live per-VLAN address inventory with bounded cardinality, but
# every series is a bare address a human has to recognise. With this metric,
#
#   nftables_set_element_bytes_total
#     * on (device, address) group_left (name) homelab_device_info
#
# names every host the inventory knows, and what is left over is exactly the
# set of devices the inventory does not know about, which is the other half
# of the answer.
#
# One machine emits this, not all of them: it is global data, and the shared
# nixos/modules/system-metrics.nix would emit a copy per machine, multiplying
# the series and fanning any join out across the copies. The server holds it
# because it is where Prometheus already runs.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (config.homelab.inventory) hosts interfaces;

  # Where node_exporter reads *.prom files from, discovered from the flag
  # that sets it in nixos/modules/system-metrics.nix rather than repeated
  # here; the same trick prometheus.nix uses to find listen ports.
  textfileFlag = "--collector.textfile.directory=";
  textfileDir = lib.removePrefix textfileFlag (
    lib.head (
      lib.filter (lib.hasPrefix textfileFlag) config.services.prometheus.exporters.node.extraFlags
    )
  );

  # The interface each host sits on, by host name: hosts carry their
  # interface name, and the interface carries the VLAN and trust level the
  # labels below report.
  interfaceOf = host: interfaces.${host.interface};

  # One row per host address, tab separated. Every field is a sops
  # placeholder or plain data; the rendering into Prometheus exposition
  # format happens in the installer below, so this template stays dumb data
  # with no syntax of its own to get wrong.
  #
  # A host appears once per address family it has, because the address is
  # the join key and a host with three addresses can be accounted under any
  # of them. That is at most three rows for each of the inventory's hosts:
  # a static set, changing only on commit.
  row =
    host: family: address:
    let
      ifi = interfaceOf host;
    in
    lib.optionalString (address != null) ''
      ${host.name}	${ifi.name}	${toString ifi.vlan}	${lib.boolToString ifi.trusted}	${host.mac}	${family}	${address}
    '';

  rows = lib.concatMapStrings (
    host: row host "ipv4" host.ipv4 + row host "ula" host.ula + row host "gua" host.gua
  ) (lib.attrValues hosts);

  # Renders the rows above as an info metric. IPv6 addresses are rewritten to
  # their canonical form on the way through, which is what makes the join
  # work at all.
  #
  # The inventory builds an address by joining a four group prefix to a four
  # group interface identifier, so it is always written out in full: a host
  # holding fd00:1234:5678:0:0:5eff:fe00:5301 is reported by the nftables
  # exporter as fd00:1234:5678::5eff:fe00:5301, because that exporter formats
  # keys with Go's netip.Addr.String (see go/internal/nftables_exporter), and
  # RFC 5952 requires the longest run of zero groups be compressed. Python's
  # ipaddress module implements the same rules and agrees character for
  # character. Without this step the two sides would never match on any host
  # whose address contains a zero run, which is every host using an eui64 or
  # token identifier.
  #
  # Rendering here rather than in the template also means the file is parsed
  # and rebuilt before it is installed: a malformed line would otherwise take
  # out node_exporter's whole textfile collector.
  render = pkgs.writers.writePython3 "homelab-inventory-metrics" { } ''
    import ipaddress
    import sys

    NAME = "homelab_device_info"
    FIELDS = ["name", "device", "vlan", "trusted", "mac", "family", "address"]


    def canonical(address: str) -> str:
        """Canonicalizes an IPv6 address, leaving anything else alone."""
        if ":" not in address:
            return address
        return str(ipaddress.IPv6Address(address))


    def escape(value: str) -> str:
        return value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


    def main() -> None:
        source, dest = sys.argv[1], sys.argv[2]

        out = [
            f"# HELP {NAME} A device in the network inventory, by address.",
            f"# TYPE {NAME} gauge",
        ]
        for line in open(source):
            line = line.rstrip("\n")
            if not line:
                continue

            values = dict(zip(FIELDS, line.split("\t"), strict=True))
            values["address"] = canonical(values["address"])

            labels = ",".join(f'{k}="{escape(v)}"' for k, v in values.items())
            out.append(f"{NAME}{{{labels}}} 1")

        with open(dest + ".tmp", "w") as f:
            f.write("\n".join(out) + "\n")


    main()
  '';
in
{
  sops.templates."inventory-metrics.tsv" = {
    content = rows;
    restartUnits = [ "homelab-inventory-metrics.service" ];
  };

  # Install the metrics file once at activation, and again whenever the
  # inventory changes: the content is fixed for the life of a system
  # generation, so unlike nixos-system-metrics there is nothing here worth
  # sampling on a timer.
  systemd.services.homelab-inventory-metrics = {
    description = "Network inventory device metrics for node_exporter";
    after = [ "sops-install-secrets.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      out=${textfileDir}/homelab-inventory.prom
      ${render} ${config.sops.templates."inventory-metrics.tsv".path} "$out"
      chmod 0444 "$out.tmp"
      mv "$out.tmp" "$out"
    '';
  };
}
