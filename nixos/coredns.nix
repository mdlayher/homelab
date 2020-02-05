{ config, lib, ... }:

let
  vars = import ./vars.nix;
  domain = vars.domain;

  guest0 = vars.interfaces.guest0;
  iot0 = vars.interfaces.iot0;
  lab0 = vars.interfaces.lab0;
  lan0 = vars.interfaces.lan0;
  wan0 = vars.interfaces.wan0;
  wg0 = vars.interfaces.wg0;

in {
  systemd.services.coredns = {
    # Delay CoreDNS startup until after WireGuard tunnel device is created.
    requires = [ "wireguard-${wg0.name}.service" ];
    after = [ "wireguard-${wg0.name}.service" ];
  };

  services.coredns = {
    enable = true;
    config = ''
      # DNS over TLS forwarding.
      (dns_forward) {
        forward . tls://8.8.8.8 tls://8.8.4.4 tls://2001:4860:4860::8888 tls://2001:4860:4860::8844 {
          tls_servername dns.google
          health_check 5s
        }
      }

      # Trusted DNS.
      . {
        bind ${vars.localhost.ipv4} ${vars.localhost.ipv6} ${lab0.ipv4} ${lab0.ipv6.ula} ${lan0.ipv4} ${lan0.ipv6.ula} ${wg0.ipv4} ${wg0.ipv6.ula}
        cache 3600 {
          success 8192
          denial 4096
        }
        prometheus :9153
        import dns_forward
      }

      # Untrusted DNS.
      . {
        bind ${guest0.ipv4} ${guest0.ipv6.ula} ${iot0.ipv4} ${iot0.ipv6.ula}
        log
        import dns_forward
      }

      # Internal DNS.
      ${domain} {
        bind ${vars.localhost.ipv4} ${vars.localhost.ipv6} ${lan0.ipv4} ${lan0.ipv6.ula} ${wg0.ipv4} ${wg0.ipv6.ula}
        cache 3600 {
          success 8192
          denial 4096
        }
        hosts ${vars.domain} {
          ${lan0.ipv4}     routnerr-2.${domain}
          ${lan0.ipv6.ula} routnerr-2.${domain}

          ${
          # Write out internal DNS records for each of the configured hosts.
          # If the host does not have an IPv6 ULA address, omit it.
            lib.concatMapStrings (host: ''
              ${host.ipv4} ${host.name}.${domain}
              ${if host.ipv6.ula != "" then ''
                ${host.ipv6.ula} ${host.name}.${domain}
              '' else
                ""}
            '') (vars.hosts.servers ++ vars.hosts.infra)
          }
        }
      }
    '';
  };
}
