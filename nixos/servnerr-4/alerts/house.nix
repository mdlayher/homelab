# The house itself, from Home Assistant's room sensors: conditions of the
# building rather than of a device. Rooms are HA areas, joined onto each
# sensor from the entity registry, so a sensor without an area is not
# monitored and assigning one is how a new room joins.
{
  raw,
  anyOf,
  ...
}:

let
  # Rooms whose humidity spikes by use: showers, cooking and the dryer
  # push them well past any sustained threshold for an hour at a time.
  # HouseHumidityVeryHigh still covers them, over a window that outlasts
  # a shower.
  wetRooms = [
    "bathroom"
    "half_bathroom"
    "basement_bathroom"
    "kitchen"
    "laundry_room"
  ];

  # The garage is unconditioned and tracks the weather, so no indoor
  # range applies to it.
  unconditioned = [ "garage" ];

  # Rooms the weather reaches: the sun heats them past any cooling
  # setpoint on a clear day, and humid air lifts them past the sustained
  # humidity threshold. HouseHumidityVeryHigh still covers them.
  sunlit = [ "sunroom" ];

  roomsExcept = areas: ''homeassistant_entity_info{area!="", area!~${raw "(${anyOf areas})"}}'';
  # A room's humidity averaged over the past hours, from sensors that have
  # reported for at least that long. A sensor re-added to Home Assistant
  # starts a new series, and its first minute is no average of anything.
  humidity =
    hours:
    "(avg_over_time(homeassistant_sensor_humidity_percent[${toString hours}h])"
    + " and on (entity) present_over_time(homeassistant_sensor_humidity_percent[1h] offset ${toString (hours - 1)}h))";

  # Room temperature in °F. Every Zigbee device also reports the
  # temperature of its own die as *_device_temperature, which is not the
  # room's.
  roomTemperature =
    window:
    "(avg_over_time(homeassistant_sensor_temperature_celsius{entity!~${raw ".*_device_temperature"}}[${window}]) * 9 / 5 + 32)";

  # How far a unit's current temperature sits from the target it is
  # working toward, in °F: the low end of a range for a thermostat in
  # heat_cool, the single setpoint for a unit in heat or cool. Positive
  # means the room has not reached the target.
  heatingShortfall = ''
    ((homeassistant_climate_target_temperature_low_celsius or homeassistant_climate_target_temperature_celsius)
      - on (entity) homeassistant_climate_current_temperature_celsius) * 9 / 5
  '';
  coolingShortfall = ''
    (homeassistant_climate_current_temperature_celsius
      - on (entity) (homeassistant_climate_target_temperature_high_celsius or homeassistant_climate_target_temperature_celsius)) * 9 / 5
  '';
  acting = action: ''on (entity) homeassistant_climate_action{action="${action}"} == 1'';
in
{
  name = "house";
  rules = [
    {
      alert = "HouseHumidityHigh";
      expr = "${humidity 24} * on (entity) group_left(area) ${
        roomsExcept (wetRooms ++ unconditioned ++ sunlit)
      } > 60";
      annotations.summary = "{{ $labels.friendly_name }} ({{ $labels.area }}) has averaged {{ $value | printf \"%.0f\" }}% humidity over the past day.";
    }
    {
      alert = "HouseHumidityVeryHigh";
      expr = "${humidity 3} * on (entity) group_left(area) ${roomsExcept unconditioned} > 70";
      annotations.summary = "{{ $labels.friendly_name }} ({{ $labels.area }}) has averaged {{ $value | printf \"%.0f\" }}% humidity over the past three hours.";
    }
    {
      alert = "HouseHumidityLow";
      expr = "${humidity 24} * on (entity) group_left(area) ${roomsExcept unconditioned} < 30";
      annotations.summary = "{{ $labels.friendly_name }} ({{ $labels.area }}) has averaged {{ $value | printf \"%.0f\" }}% humidity over the past day.";
    }
    {
      alert = "HouseTemperatureLow";
      expr = "${roomTemperature "1h"} * on (entity) group_left(area) ${roomsExcept unconditioned} < 55";
      annotations.summary = "{{ $labels.friendly_name }} ({{ $labels.area }}) has averaged {{ $value | printf \"%.0f\" }} °F over the past hour.";
    }
    {
      alert = "HouseTemperatureHigh";
      expr = "${roomTemperature "1h"} * on (entity) group_left(area) ${
        roomsExcept (unconditioned ++ sunlit)
      } > 85";
      annotations.summary = "{{ $labels.friendly_name }} ({{ $labels.area }}) has averaged {{ $value | printf \"%.0f\" }} °F over the past hour.";
    }
    # A unit that keeps running without closing on its target: a struggling
    # furnace or compressor, a clogged filter, a stuck damper.
    {
      alert = "HVACNotReachingTarget";
      expr = ''
        (${heatingShortfall} > 3 and ${acting "heating"})
          or
        (${coolingShortfall} > 3 and ${acting "cooling"})
      '';
      for = "3h";
      annotations.summary = "{{ $labels.friendly_name }} has run for hours and is still {{ $value | printf \"%.0f\" }} °F short of its target.";
    }
  ];
}
