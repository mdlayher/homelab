{ config, ... }:

{
    services.prometheus.exporters.node.enable = true;
}
