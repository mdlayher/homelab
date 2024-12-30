# Variables referenced two or more places in the configuration.
let
  # Import computed host/interface data from vars.json.
  gen = builtins.fromJSON (builtins.readFile ./vars.json);
  hosts = gen.hosts;
  interfaces = gen.interfaces;
  wireguard = gen.wireguard;

  server_ipv4 = gen.server_ipv4;
  server_ipv6 = gen.server_ipv6;
  desktop_ipv4 = gen.desktop_ipv4;
  desktop_ipv6 = gen.desktop_ipv6;

in
{
  inherit hosts;
  inherit interfaces;
  inherit wireguard;

  inherit server_ipv4;
  inherit server_ipv6;
  inherit desktop_ipv4;
  inherit desktop_ipv6;

  domain = "lan.servnerr.com";
  localhost = {
    ipv4 = "127.0.0.1";
    ipv6 = "::1";
  };
}
