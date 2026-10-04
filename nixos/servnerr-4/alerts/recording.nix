# Recording rules, named level:metric:operations like Loki's
# host:log_lines:count1h; see loki.nix. Alerts in the other groups read them.
{
  lib,
  raw,
  railBoard,
  rails,
  withDrive,
  ...
}:

{
  name = "recording";
  rules = [
    # BGP session state changes per hour, as a series to graph and alert
    # on rather than a query to remember. BIRDBGPSessionDown needs ten
    # straight minutes down, so a session bouncing every few minutes
    # never trips it and only shows up here.
    #
    # The subquery is load-bearing: the exporter puts a state label
    # (Established, Active, Idle ... Error: ...) on a BGP protocol's
    # IPv4 channel, so each state change there starts a new series, each
    # of them constant for its life, and changes() over the raw metric
    # counts nothing for IPv4. Collapsing to one series per session and
    # channel first, at scrape resolution, is what makes the count
    # right. Not filtered to external peers: the internal dn42i_*
    # sessions are expected to bounce, and it is the alerts, not the
    # record, that leave them out.
    # SMART error counters keyed by drive rather than device name, for
    # SMARTErrorLogGrowing: increase() over a device-named counter
    # compares two drives' counts across a renumber.
    {
      record = "instance_serial:smartctl_device_error_log_count:max";
      expr = withDrive "smartctl_device_error_log_count";
    }
    {
      record = "instance_serial:smartctl_device_media_errors:max";
      expr = withDrive "smartctl_device_media_errors";
    }
    {
      record = "instance_name_ip_version:bird_protocol_up:changes1h";
      expr = ''changes((max by (instance, name, ip_version) (bird_protocol_up{proto="BGP"}))[1h:15s])'';
    }
  ]
  # The server board's power rails in volts, and as a fraction of each
  # rail's nominal voltage; see rails in default.nix.
  ++ lib.concatMap (r: [
    {
      record = "instance_rail:node_hwmon_in_volts:scaled";
      expr = ''
        node_hwmon_in_volts{chip=~"platform_nct6775_.*",sensor="${r.sensor}"} * ${toString r.factor}
          and on (instance) node_dmi_info{board_name="${railBoard}"}
      '';
      labels.rail = r.rail;
    }
    {
      record = "instance_rail:node_hwmon_in_volts:nominal_ratio";
      expr = ''instance_rail:node_hwmon_in_volts:scaled{rail="${r.rail}"} / ${toString r.nominal}'';
      labels.rail = r.rail;
    }
  ]) rails;
}
