# Power and environment: the UPS, the PDU, the rack's temperature and
# humidity, and Home Assistant's battery-powered sensors.
{
  environmentSensorInstances,
  ...
}:

{
  name = "power";
  rules = [
    {
      alert = "APCUPSBatteryTimeLeft";
      expr = "apcupsd_battery_time_on_seconds > 0 and apcupsd_battery_time_left_seconds < 30*60";
      annotations.summary = "UPS on {{ $labels.instance }} has less than 30 minutes of remaining battery runtime.";
    }
    {
      alert = "APCUPSOnBattery";
      expr = "apcupsd_battery_time_on_seconds > 0";
      annotations.summary = "UPS on {{ $labels.instance }} is running on battery power.";
    }
    # Battery-powered sensors die silently: the entity goes unavailable
    # and its data just stops. The join against the entity registry keeps
    # only sensors assigned to an area of the house, which excludes
    # personal devices (phones, tablets) that run low routinely and
    # charge themselves; assign an area to a new sensor and it is
    # monitored.
    {
      alert = "HomeAssistantBatteryLow";
      expr = ''homeassistant_sensor_battery_percent * on (entity) group_left(area) homeassistant_entity_info{area!=""} < 15'';
      for = "1h";
      annotations.summary = "Home Assistant sensor {{ $labels.friendly_name }} ({{ $labels.area }}) battery is at {{ $value }}%.";
    }
    # The Zigbee smart plugs are routers for the mesh and metered outlets,
    # never switched loads: their switch entities are disabled in Home
    # Assistant, and the server's zigbee snapshot reads each relay from
    # the plug every 15 minutes. A relay off is the plug's own button or
    # a power-on default, and takes the mesh hop and the metering with it.
    {
      alert = "ZigbeePlugOff";
      expr = "homelab_zigbee_plug_on == 0";
      annotations.summary = "Zigbee plug {{ $labels.device }} has its relay switched off.";
    }
    # ZHA's own verdict on a device, after its per-class timeout (hours
    # for battery devices, less for mains). A plug gone this way takes
    # its mesh hop with it, and a dead leak sensor reports no leaks.
    {
      alert = "ZigbeeDeviceUnavailable";
      expr = "homelab_zigbee_device_available == 0";
      for = "30m";
      annotations.summary = "Zigbee device {{ $labels.device }} is unavailable to ZHA.";
    }
    # The KVM's fan, as kvmd's fan controller reports it.
    # A PDU bank past the near-overload threshold configured on the PDU
    # itself (3 is nearOverload, 4 overload).
    {
      alert = "PDUBankOverloaded";
      expr = "ePDU2BankStatusLoadState >= 3";
      for = "5m";
      annotations.summary = "Bank {{ $labels.ePDU2BankStatusIndex }} of {{ $labels.instance }} is near or past overload.";
    }
    # The rack's environment sensor against the thresholds set on the
    # card it is attached to, so changing a threshold there changes the
    # alert. A card with no sensor attached reads zero, which this
    # reports as out of range.
    {
      alert = "RackHumidityOutOfRange";
      expr = ''
        envirHumidity{instance=~${environmentSensorInstances}} > envirHumidHighThreshold
          or
        envirHumidity{instance=~${environmentSensorInstances}} < envirHumidLowThreshold
      '';
      for = "15m";
      annotations.summary = "Rack humidity reported by {{ $labels.instance }} is {{ $value }}%, outside the card's thresholds.";
    }
    {
      alert = "RackTemperatureOutOfRange";
      expr = ''
        envirTemperature{instance=~${environmentSensorInstances}} / 10 > envirTempHighThreshold
          or
        envirTemperature{instance=~${environmentSensorInstances}} / 10 < envirTempLowThreshold
      '';
      for = "15m";
      annotations.summary = "Rack temperature reported by {{ $labels.instance }} is {{ $value }} °F, outside the card's thresholds.";
    }
    # The UPS's own battery verdicts, read from its management card.
    {
      alert = "UPSBatteryNeedsReplacing";
      expr = "upsAdvanceBatteryReplaceIndicator == 2";
      for = "15m";
      annotations.summary = "The UPS behind {{ $labels.instance }} reports that its batteries need replacing.";
    }
    {
      alert = "UPSLoadHigh";
      expr = "upsAdvanceOutputLoad > 80";
      for = "5m";
      annotations.summary = "{{ $labels.instance }} is carrying {{ $value }}% of its rated load.";
    }
    {
      alert = "UPSSelfTestFailed";
      expr = "upsAdvanceTestDiagnosticsResults == 2";
      annotations.summary = "The UPS behind {{ $labels.instance }} failed its last self-test.";
    }
  ];
}
