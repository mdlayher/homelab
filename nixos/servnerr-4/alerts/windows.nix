# The Windows PCs (see windows/), from HWiNFO. The PCs are often off, so
# these read only what a PC reports while it is on.
{
  ...
}:

{
  name = "windows";
  rules = [
    # The gaming PC's GPU power cable, as the WireView Pro II inline on its
    # 12V-2x6 connector reports it through HWiNFO (see
    # go/internal/hwinfo_exporter). Its own verdicts come first, so its
    # limits are set in Thermal Grizzly's software rather than here. The
    # per-pin backstop catches a pin carrying too much while the device's
    # limits are set loose; the connector's terminals are rated around
    # 9.5 A each. Both read only while the PC runs HWiNFO, so they cannot
    # fire while it is off.
    {
      alert = "GPUPowerConnectorFlagged";
      expr = ''hwinfo_sensor_value{sensor=~"Thermal Grizzly WireView.*",unit="Yes/No",label=~"Current Imbalance|Over Current Limit Exceeded.*|Power Limit Exceeded|Temperature Limit Exceeded.*"} == 1'';
      for = "30s";
      annotations.summary = "The WireView on {{ $labels.instance }} reports {{ $labels.label }} on the GPU's power connector.";
    }
    {
      alert = "GPUPowerPinCurrentHigh";
      expr = ''hwinfo_sensor_value{sensor=~"Thermal Grizzly WireView.*",label=~"Pin [0-9]+ Current"} > 9'';
      for = "30s";
      annotations.summary = "{{ $labels.label }} on the GPU's power connector at {{ $labels.instance }} is {{ $value | printf \"%.2f\" }} A, above the 9 A backstop.";
    }
    # Errors Windows logs for the hardware itself (WHEA): machine checks,
    # PCIe and memory errors. HWiNFO counts them since it started.
    {
      alert = "WindowsHardwareErrors";
      expr = ''increase(hwinfo_sensor_value{sensor="Windows Hardware Errors (WHEA)", label="Total Errors"}[1h]) > 0'';
      annotations.summary = "{{ $labels.instance }} logged {{ $value | humanize }} Windows hardware errors (WHEA) in the last hour.";
    }
    # The drive's own SMART verdicts, as HWiNFO reads them.
    {
      alert = "WindowsSMARTDriveWarning";
      expr = ''hwinfo_sensor_value{sensor=~"S\\.M\\.A\\.R\\.T\\..*", label=~"Drive Warning|Drive Failure"} > 0'';
      annotations.summary = "{{ $labels.sensor }} on {{ $labels.instance }} reports {{ $labels.label }}.";
    }
  ];
}
