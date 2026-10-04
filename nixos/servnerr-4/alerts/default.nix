# Prometheus rules, a group per area of the homelab with each in a file of
# its own here, then the recording rules.
# Host and job specifics come from the inventory in prometheus.nix rather
# than being hardcoded here; the helpers below are shared by every group.
{
  lib,
  # Every anycast service address and the site expected to answer it, as
  # { service, address, site }; see nixos/modules/anycast.nix.
  anycastServices,
  # How many routers run the IGP at each level, and so how many LSPs each
  # link-state database should hold: { level2, level1.<site> }.
  isisRouterCounts,
  # Builds a Grafana Explore link for a LogQL query, for alerts which fire on
  # what Loki's ruler records; see nixos/servnerr-4/explore-url.nix.
  exploreURL,
  # Hosts which don't run 24/7 and should never raise down alerts.
  excludedHosts,
  # Jobs whose targets are too unreliable to raise down alerts, or whose
  # down state other rules already report on better thresholds.
  excludedJobs,
  # Hosts acting as routers, whose CoreRAD default route comes from the WAN.
  routers,
  # Hosts whose root filesystem is mounted read-only except while edited.
  readOnlyRoots,
  # Hosts expected to ship their journals to Loki.
  logHosts,
  # SNMP targets with an environment sensor attached, by instance.
  environmentSensors,
}:

let
  # Regular expressions are emitted as PromQL raw strings (backticks) so that
  # escaped characters survive.
  raw = s: "`${s}`";
  anyOf = xs: lib.concatMapStringsSep "|" lib.escapeRegex xs;

  # Matches an instance label ("host:port", or a probe URL) for any of hosts.
  hostsRegex = hosts: raw "(${anyOf hosts}):.*";

  # Internal dn42 sessions and links (see the router's dn42.nix): dn42i_ is
  # the bird protocol prefix, dn42i- the interface prefix. What is on the
  # other end is an implementation under development rather than a service,
  # so it is expected to be down, and to be broken on purpose while someone
  # works on it. The external dn42e_ peers still alert normally.
  internalProtocols = raw "dn42i_.*";

  # The iBGP sessions between the dn42 nodes' loopbacks (ibgp_<machine>,
  # see modules/dn42.nix): a site without peers of its own exports nothing
  # over them, so the peering site's end is Established and empty by
  # design. Session state still alerts; an empty import does not.
  interconnectProtocols = raw "ibgp_.*";
  internalInterfaces = raw "dn42i-.*";

  # The IS-IS sample, matched on its name so the textfile directory's path
  # is not repeated here; node_exporter labels each file by its full path.
  isisTextfile = raw ".*/isis\\.prom";
  notifyTextfile = raw ".*/update-notify\\.prom";

  # The server board's power rails as its Super I/O reads them. The chip
  # sees the 5 V and 12 V rails through resistor dividers the driver does
  # not know, so those inputs are multiplied back up; the factors match
  # LibreHardwareMonitor's tables for ASUS X570 boards with the same
  # NCT6798D. The 3.3 V inputs arrive already scaled by the driver.
  #
  # The 12 V and 5 V inputs have never changed by one step of the chip
  # (96 mV and 40 mV after scaling), at idle or under full CPU load, so
  # whether they track the rails at all is unconfirmed; the 3.3 V inputs
  # do move.
  railBoard = "ROG STRIX X570-E GAMING";
  rails = [
    {
      rail = "+12V";
      sensor = "in4";
      factor = 12;
      nominal = 12;
    }
    {
      rail = "+5V";
      sensor = "in1";
      factor = 5;
      nominal = 5;
    }
    {
      rail = "+3.3V";
      sensor = "in3";
      factor = 1;
      nominal = 3.3;
    }
    {
      rail = "+3.3V standby";
      sensor = "in7";
      factor = 1;
      nominal = 3.3;
    }
  ];

  excludedInstances = hostsRegex excludedHosts;
  routerInstances = hostsRegex routers;
  readOnlyRootInstances = hostsRegex readOnlyRoots;
  environmentSensorInstances = raw (anyOf environmentSensors);
  excludedJobsRegex = raw (anyOf excludedJobs);

  # The smartctl exporter keys every metric by kernel device name, which is
  # not stable across reboots, and carries the model and serial only on its
  # smartctl_device info metric. Joining those in and dropping the device
  # name keys each series by the physical drive, so a renumber neither
  # re-fires an alert under a new name nor moves one drive's counters onto
  # another, and a silence on the serial keeps matching. Both come from one
  # scrape, so the info series is never missing alone.
  #
  # Only each device name's freshest info series joins. A restarted
  # Prometheus evaluates samples from before it went down, with no
  # staleness markers, so after a reboot that renumbered the drives two
  # serials can hold one name until the old sample ages out, and the join
  # would fail on the duplicate.
  currentDrives = "(smartctl_device and on (instance, device, serial_number) (timestamp(smartctl_device) == on (instance, device) group_left () max by (instance, device) (timestamp(smartctl_device))))";
  withDrive =
    expr:
    "max without (device) ((${expr}) * on (instance, device) group_left(model_name, serial_number) ${currentDrives})";

  # The drive's current device name, for a summary: looked up by serial at
  # notification time, since the alert itself no longer carries it.
  driveDevice = ''{{ with printf "smartctl_device{serial_number='%s'}" $labels.serial_number | query }}{{ . | first | label "device" }}{{ end }}'';

  # The same join for a metric recorded by Loki's ruler, which labels by host
  # rather than instance. The host is derived from the instance label so that
  # no domain or exporter port is repeated here.
  withDriveByHost =
    expr:
    "max without (device) ((${expr}) * on (host, device) group_left(model_name, serial_number) "
    + ''label_replace(${currentDrives}, "host", "$1", "instance", ${raw "([^.:]+).*"}))'';

  # One rule per site and service address. A single node withdrawing its
  # address is the design working; a site where nothing holds it is not.
  # absent() because a count has no series at zero, guarded on the site
  # answering at all so a dead exporter is not read as a withdrawal.
  anycastRules = map (s: {
    alert = "AnycastAddressMissing";
    expr = ''
      absent(node_network_address_info{device="anycast", address="${s.address}", site="${s.site}"})
      and on () count(up{job="node", site="${s.site}"} == 1) > 0
    '';
    for = "10m";
    labels = { inherit (s) site address; };
    annotations.summary = "No node at site ${s.site} holds ${s.address}, so nothing there answers ${s.service} and every request from its clients crosses the fabric.";
  }) anycastServices;

  shared = {
    inherit
      lib
      anycastServices
      isisRouterCounts
      exploreURL
      excludedHosts
      excludedJobs
      routers
      readOnlyRoots
      logHosts
      environmentSensors
      raw
      anyOf
      hostsRegex
      internalProtocols
      interconnectProtocols
      internalInterfaces
      isisTextfile
      notifyTextfile
      railBoard
      rails
      excludedInstances
      routerInstances
      readOnlyRootInstances
      environmentSensorInstances
      excludedJobsRegex
      currentDrives
      withDrive
      driveDevice
      withDriveByHost
      anycastRules
      ;
  };
in
{
  groups = map (file: import file shared) [
    ./routing.nix
    ./network.nix
    ./hardware.nix
    ./storage.nix
    ./power.nix
    ./systems.nix
    ./windows.nix
    ./pikvm.nix
    ./recording.nix
  ];
}
