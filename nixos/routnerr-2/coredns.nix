{ lib, ... }:

let vars = import ./lib/vars.nix;

in {
  services.coredns = {
    enable = true;
    config = with vars; ''
      # Root zone.
      . {
        cache 3600 {
          success 8192
          denial 4096
        }
        prometheus :9153
        forward . tls://8.8.8.8 tls://8.8.4.4 tls://2001:4860:4860::8888 tls://2001:4860:4860::8844 {
          tls_servername dns.google
          health_check 5s
        }
      }

      # Internal zone.
      ${domain} {
        hosts {
          ${
          # Write out internal DNS records for each of the configured hosts.
          # If the host does not have an IPv6 ULA address, omit it.
            lib.concatMapStrings (host: ''
              ${host.ipv4} ${host.name}.${domain}
              ${host.ipv4} ${host.name}.ipv4.${domain}

              ${if host.ipv6.ula != "" then ''
                ${host.ipv6.ula} ${host.name}.${domain}
                ${host.ipv6.ula} ${host.name}.ipv6.${domain}
              '' else
                ""}
            '') (hosts.servers ++ hosts.infra ++ [{
              name = "routnerr-2";
              ipv4 = interfaces.lan0.ipv4;
              ipv6.ula = interfaces.lan0.ipv6.ula;
            }])
          }
        }
      }
    '';
  };
}
