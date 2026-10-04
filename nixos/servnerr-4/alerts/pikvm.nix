# The KVM (see pikvm/), from the health metrics it exports.
{
  ...
}:

{
  name = "pikvm";
  rules = [
    {
      alert = "PiKVMFanFailed";
      expr = "pikvm_fan_state_fan_ok == 0";
      for = "5m";
      annotations.summary = "The fan on {{ $labels.instance }} has failed.";
    }
    # The firmware's live throttling flags, from kvmd: the ARM clock
    # throttled or capped, for heat or for voltage. Each also has a flag
    # latched since boot, which these rules leave alone.
    {
      alert = "PiKVMThrottled";
      expr = "pikvm_hw_throttling_throttled_now == 1 or pikvm_hw_throttling_freq_capped_now == 1";
      for = "10m";
      annotations.summary = "{{ $labels.instance }} has been throttling its CPU for 10 minutes.";
    }
    {
      alert = "PiKVMUndervoltage";
      expr = "pikvm_hw_throttling_undervoltage_now == 1";
      for = "2m";
      annotations.summary = "{{ $labels.instance }} is undervolted; check its power supply.";
    }
  ];
}
