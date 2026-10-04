# Hardware sensors on the Linux machines: temperatures, fans and power rails.
{
  rails,
  excludedInstances,
  ...
}:

{
  name = "hardware";
  rules = [
    # As with BIRDExporterFailing: a failed command socket query drops the
    # chrony metrics rather than zeroing them, so every rule below goes
    # quiet exactly when this one fires.
    # Tctl, the temperature the CPU throttles on; k10temp reports it as
    # temp1.
    {
      alert = "CPUTemperatureHigh";
      expr = ''
        node_hwmon_temp_celsius{instance!~${excludedInstances},sensor="temp1"}
          * on (instance, chip) group_left (chip_name)
        node_hwmon_chip_names{chip_name="k10temp"}
          > 90
      '';
      for = "10m";
      annotations.summary = "The CPU on {{ $labels.instance }} has been at {{ $value }} °C for 10 minutes.";
    }
    # A fan header which has spun within the week and now reads zero.
    # Headers with nothing attached never spin, so they never match,
    # and the week keeps a dead fan firing well past the day it stopped.
    # The ASUS EC's chipset fan stops by design when the chipset is cool;
    # it is matched by label, since its sensor number depends on which
    # other EC fans the driver reports.
    {
      alert = "FanStopped";
      expr = ''
        node_hwmon_fan_rpm{instance!~${excludedInstances}} == 0
          unless on (instance, chip, sensor)
        node_hwmon_sensor_label{chip="platform_asus_ec_sensors",label="Chipset"}
          and on (instance, chip, sensor)
        max_over_time(node_hwmon_fan_rpm[7d]) > 0
      '';
      for = "2m";
      annotations.summary = "Fan {{ $labels.sensor }} ({{ $labels.chip }}) on {{ $labels.instance }} reads 0 RPM after spinning within the last week.";
    }
    # The SAS HBA cools passively and idled at 71–80 °C when first
    # measured; see the server's hba-metrics.nix.
    {
      alert = "HBATemperatureHigh";
      expr = "homelab_hba_temperature_celsius > 90";
      for = "10m";
      annotations.summary = "SAS HBA controller {{ $labels.controller }} on {{ $labels.instance }} is at {{ $value }} °C.";
    }
    # A power rail outside the ATX specification's ±5%, the usual first
    # sign of a failing power supply; see rails in default.nix.
    {
      alert = "PowerRailOutOfRange";
      expr = ''
        instance_rail:node_hwmon_in_volts:scaled
          and on (instance, rail)
        abs(instance_rail:node_hwmon_in_volts:nominal_ratio - 1) > 0.05
      '';
      for = "5m";
      annotations.summary = "The {{ $labels.rail }} rail on {{ $labels.instance }} reads {{ $value | printf \"%.2f\" }} V, outside ±5% of nominal.";
    }
  ];
}
