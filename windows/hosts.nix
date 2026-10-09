# The Windows PCs, the inventory hosts tagged windows, and the exporters
# each of them runs, read by the server's Prometheus
# (nixos/servnerr-4/prometheus.nix) for its scrape jobs and by
# windows/default.nix for what windows/deploy installs.
{
  hosts = import ../nixos/inventory/tagged.nix "windows";

  # Prometheus job names and their ports.
  exporters = {
    # Grafana Alloy's own metrics, the same job as the Linux machines'.
    alloy = 12345;
    # go/internal/hwinfo_exporter, reading HWiNFO's shared memory.
    hwinfo = 9888;
    # nvidia_gpu_exporter, reading nvidia-smi.
    nvidia_gpu = 9835;
    windows = 9182;
  };
}
