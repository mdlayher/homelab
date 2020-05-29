# Variables referenced two or more places in the configuration.
let
  # Import computed host/interface data from vars.json.
  gen = builtins.fromJSON (builtins.readFile ./vars.json);
  server_ipv4 = gen.server_ipv4;
  server_ipv6 = gen.server_ipv6;
  hosts = gen.hosts;
  interfaces = gen.interfaces;
  wireguard = gen.wireguard;

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
