# Variables referenced two or more places in the configuration.
let
  # TODO: remove and pull from generated data.
  server_ipv4 = "192.168.1.4";
  server_ipv6 = "2600:6c4a:7880:3200:1e1b:dff:feea:830f";

  # Import computed host/interface data from vars.json.
  gen = builtins.fromJSON (builtins.readFile ./vars.json);
  hosts = gen.hosts;
  interfaces = gen.interfaces;
in {
  inherit server_ipv4;
  inherit server_ipv6;
  inherit hosts;
  inherit interfaces;

  domain = "lan.servnerr.com";
  localhost = {
    ipv4 = "127.0.0.1";
    ipv6 = "::1";
  };
}
