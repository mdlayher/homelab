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
  # humidity range applies to it.
  unconditioned = [ "garage" ];

  roomsExcept = areas: ''homeassistant_entity_info{area!="", area!~${raw "(${anyOf areas})"}}'';
  humidity = window: "avg_over_time(homeassistant_sensor_humidity_percent[${window}])";
in
{
  name = "house";
  rules = [
    {
      alert = "HouseHumidityHigh";
      expr = "${humidity "24h"} * on (entity) group_left(area) ${
        roomsExcept (wetRooms ++ unconditioned)
      } > 60";
      annotations.summary = "{{ $labels.friendly_name }} ({{ $labels.area }}) has averaged {{ $value | printf \"%.0f\" }}% humidity over the past day.";
    }
    {
      alert = "HouseHumidityVeryHigh";
      expr = "${humidity "3h"} * on (entity) group_left(area) ${roomsExcept unconditioned} > 70";
      annotations.summary = "{{ $labels.friendly_name }} ({{ $labels.area }}) has averaged {{ $value | printf \"%.0f\" }}% humidity over the past three hours.";
    }
    {
      alert = "HouseHumidityLow";
      expr = "${humidity "24h"} * on (entity) group_left(area) ${roomsExcept unconditioned} < 30";
      annotations.summary = "{{ $labels.friendly_name }} ({{ $labels.area }}) has averaged {{ $value | printf \"%.0f\" }}% humidity over the past day.";
    }
  ];
}
