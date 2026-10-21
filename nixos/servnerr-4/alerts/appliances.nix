# Household appliances, from the power each draws through its Zigbee plug.
# The plug's relay has its own rule (ZigbeePlugOff); these read the load
# behind a relay that is on. A relay switched off takes the load's power
# to zero and fires the first rule here as well.
{
  raw,
  anyOf,
  ...
}:

let
  # Appliances with a compressor that cycles between running and resting,
  # matched by what the plug's entity says it feeds. The plug sees each
  # run as minutes of load, so the scrape catches every one.
  compressorPlugs = raw "sensor\\..*_(refrigerator|freezer)_plug_power";

  # The kitchen refrigerator has an inverter compressor that runs at low
  # power most of the time, so it never rests and is left out of the rule
  # that expects a rest.
  inverterPlugs = [ "sensor.kitchen_refrigerator_plug_power" ];

  compressors = "homeassistant_sensor_power_w{entity=~${compressorPlugs}}";
  restingCompressors = "homeassistant_sensor_power_w{entity=~${compressorPlugs}, entity!~${raw "(${anyOf inverterPlugs})"}}";
in
{
  name = "appliances";
  rules = [
    {
      alert = "CompressorNotRunning";
      expr = "max_over_time(${compressors}[3h]) < 5";
      annotations.summary = "{{ $labels.friendly_name }} has drawn no power for three hours.";
    }
    {
      alert = "CompressorNotResting";
      expr = "min_over_time(${restingCompressors}[3h]) > 20";
      annotations.summary = "{{ $labels.friendly_name }} has run without a rest for three hours, drawing at least {{ $value | printf \"%.0f\" }} W.";
    }
  ];
}
