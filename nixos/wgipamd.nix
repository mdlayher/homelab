{ config, ... }:

let vars = import ./vars.nix;

in {
  services.wgipamd = {
    enable = true;
    # TODO: templating.
    config = ''
      # wgipamd vALPHA configuration file

      [storage]
      # TODO persistent storage.

      [[interfaces]]
      name = "wg0"
      lease_duration = "30s"

        # wg0 IPv4
        [[interfaces.subnets]]
        subnet = "192.168.20.0/24"
        start = "192.168.20.10"
        end = "192.168.20.50"

        # wg0 IPv6 GUA
        [[interfaces.subnets]]
        subnet = "2600:6c4a:787f:d120::/64"
        start = "2600:6c4a:787f:d120::10"

        # TODO: enable whenever wg-dynamic-client can handle this properly.
        # wg0 IPv6 ULA
        # [[interfaces.subnets]]
        # subnet = "fd9e:1a04:f01d:20::/64"
        # start = "fd9e:1a04:f01d:20::10"

      [debug]
      # debug on lan0
      address = "[fd9e:1a04:f01d::1]:9475"
      prometheus = true
      pprof = true
                '';
  };
}
