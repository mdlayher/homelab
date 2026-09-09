# The dn42 peering page, https://azo.dn42.mdlayher.net: what a prospective
# peer needs to set up a session, generated from the dn42.nix options so it
# cannot drift from the tunnels and bird.
#
# Served from the router, the one host with both a WAN and a dn42 address,
# so it answers from the clearnet and from inside dn42 without NAT in the
# way. The page names how the client reached it, the address family and
# dn42 when through it, from the accepted connection: a connection to one
# of the router's dn42 addresses came through dn42, since those addresses
# exist nowhere else, and the client's address gives the family. It also
# names the HTTP version the request arrived over, and HTTP/3 is enabled
# so that can be any of the three: the first connection is HTTP/1.1 or
# HTTP/2 over TCP, and the Alt-Svc header it carries sends the client to
# QUIC on UDP 443 for the next one.
#
# Inside dn42 the same page answers under our registry name, with a
# certificate from the dn42 CA for anyone who has installed its root, and
# plain HTTP for everyone else.
#
# v1 is static. The fixed points for a later server to drop into are the
# certificates under /var/lib/acme/<domain>/, which the acme module renews
# on its own, and ports 80 and 443, TCP and UDP, on every address.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  dn42 = config.homelab.dn42;

  # The public name, a CNAME to the apex in terraform/cloudflare, and its
  # single-family variants, CNAMEs to the current-egress names the router
  # publishes from cloudflare-ddns.nix. The certificate covers the apex
  # and the wildcard beneath it.
  domain = "azo.dn42.mdlayher.net";

  # The Cloudflare token cloudflare-ddns.nix already decrypts onto the
  # router, DNS:Edit on both zones, which is what the DNS-01 challenge
  # needs; a wildcard is only issued against DNS-01. lego reads it from a
  # differently named variable than the updater does, so the same secret is
  # rendered a second time rather than adding a second credential.
  secret = "cloudflare/ddns_token";

  # The dn42 CA's ACME service, run by burble inside dn42: HTTP-01, which
  # the router reaches from its own dn42 address, resolving the name
  # through the dn42 forwarder in coredns.nix; the validation request
  # arrives on port 80 of our dn42 address, open in nftables.nix. The
  # service's own certificate is dn42-signed too, and lego trusts it the
  # way everything on this machine does, through the system store, where
  # dn42.nix puts the dn42 root (see nixos/modules/dn42-ca.nix).
  # Certificates are issued for 30 days; renewing at 20 on the daily timer
  # leaves enough attempts before one lapses.
  dn42Acme = "https://acme.burble.dn42/v1/dn42/acme/directory";

  # The single-family names inside dn42, beneath the apex as on the
  # clearnet; see the zone in coredns.nix.
  familyPrefixes = [
    "ipv4."
    "ipv6."
  ];

  # A redirect vhost from an azo name to its counterpart under the apex.
  azoRedirect = prefix: {
    addSSL = true;
    useACMEHost = dn42.domain;
    locations."/".return = "301 $scheme://${prefix}${dn42.domain}$request_uri";
  };

  # A single self-contained page: no scripts, nothing fetched. Two facts
  # about the connection are per request rather than baked in, so the file
  # names neither and nginx rewrites both on the way out (see the maps and
  # sub_filter in the vhost): "HTTP" becomes the negotiated version, and
  # "IP" the client's address family, prefixed with dn42 when the client
  # came through it. The file reads sensibly on its own.
  page =
    let
      peerRows = lib.concatStrings (
        lib.mapAttrsToList (name: peer: ''
          <tr><td>${name}</td><td>AS${toString peer.asn}</td><td>${toString peer.port}</td></tr>
        '') dn42.peers
      );
    in
    ''
      <!DOCTYPE html>
      <html lang="en">
      <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>AS${toString dn42.asn} azo: dn42 peering</title>
      <style>
      :root {
        --bg: #f7f7f2;
        --fg: #222;
        --muted: #666;
        --rule: #ddd;
        --link: #1a5fb4;
      }
      @media (prefers-color-scheme: dark) {
        :root {
          --bg: #15171c;
          --fg: #e4e6eb;
          --muted: #9aa0ab;
          --rule: #33373f;
          --link: #8ab4ff;
        }
      }
      body {
        max-width: 42rem;
        margin: 0 auto;
        padding: 2rem 1.25rem 3rem;
        font: 16px/1.5 system-ui, -apple-system, "Segoe UI", sans-serif;
        color: var(--fg);
        background: var(--bg);
      }
      h1 { margin: 0; font-size: 1.75rem; }
      h1 small { font-weight: normal; color: var(--muted); font-size: 1.1rem; }
      h2 { font-size: 1.15rem; margin: 2rem 0 .5rem; }
      p { margin: .5rem 0; }
      a { color: var(--link); }
      .vantage { color: var(--muted); }
      table { border-collapse: collapse; width: 100%; }
      th, td { text-align: left; vertical-align: top; padding: .35rem .5rem; border-bottom: 1px solid var(--rule); }
      th { white-space: nowrap; font-weight: 600; width: 9rem; }
      code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: .95em; overflow-wrap: anywhere; }
      footer { margin-top: 2.5rem; color: var(--muted); font-size: .9rem; }
      </style>
      </head>
      <body>
      <h1>AS${toString dn42.asn} <small>azo, dn42</small></h1>
      <p class="vantage">Connected via HTTP over IP.</p>

      <p>
        The Kalamazoo, Michigan, USA node of a
        <a href="https://dn42.dev">dn42</a> network run by
        <a href="https://mdlayher.com">mdlayher</a>. Open to peering: send
        your ASN, WireGuard public key, endpoint, and link-local address.
      </p>

      <h2>Peering</h2>
      <table>
        <tr><th>ASN</th><td><code>AS${toString dn42.asn}</code></td></tr>
        <tr><th>Endpoint</th><td>
          <a href="https://${domain}/"><code>${domain}</code></a><br>
          <a href="https://ipv4.${domain}/"><code>ipv4.${domain}</code></a> to pin IPv4<br>
          <a href="https://ipv6.${domain}/"><code>ipv6.${domain}</code></a> to pin IPv6
        </td></tr>
        <tr><th>Port</th><td><code>2xxxx</code>, the last four digits of your ASN</td></tr>
        <tr><th>WireGuard key</th><td><code>${dn42.publicKey}</code></td></tr>
        <tr><th>MTU</th><td><code>1420</code></td></tr>
        <tr><th>Link-local</th><td><code>${dn42.lla}</code></td></tr>
        <tr><th>Session</th><td>MP-BGP over link-local, IPv4 via extended next hop; BFD on request</td></tr>
        <tr><th>Addresses</th><td><code>${dn42.addr4}</code>, <code>${dn42.addr6}</code></td></tr>
        <tr><th>Prefixes</th><td><code>${dn42.net4}</code>, <code>${dn42.net6}</code></td></tr>
        <tr><th>Routing</th><td>BIRD 2 with ROA validation</td></tr>
      </table>

      <h2>Peers</h2>
      <table>
        <tr><th>Peer</th><th>ASN</th><th>Our port</th></tr>
        ${peerRows}
      </table>

      <footer>
        <p>
          Inside dn42:<br>
          <a href="https://${dn42.domain}/"><code>https://${dn42.domain}/</code></a> with the dn42 CA root installed<br>
          <a href="http://${dn42.domain}/"><code>http://${dn42.domain}/</code></a><br>
          <a href="http://ipv4.${dn42.domain}/"><code>ipv4.${dn42.domain}</code></a> to pin IPv4,
          <a href="http://ipv6.${dn42.domain}/"><code>ipv6.${dn42.domain}</code></a> to pin IPv6
        </p>
      </footer>
      </body>
      </html>
    '';

  root = pkgs.runCommand "azo-page" { } ''
    install -Dm444 ${pkgs.writeText "index.html" page} $out/index.html
  '';

  # The version rewrite: the file says "via HTTP over", the response says
  # which. Once, since the phrase appears once; the type filter defaults
  # to text/html, which is all that is served here. sub_filter cannot see
  # through a compressed body, and nothing here compresses (no gzip, and
  # no gzip_static beside the files). Shared by both names the page has.
  locations."= /".extraConfig = ''
    try_files /index.html =404;
    sub_filter 'via HTTP over IP' 'via $vantage';
    sub_filter_once on;
  '';
in
{
  sops.templates."acme-cloudflare.env" = {
    content = ''
      CLOUDFLARE_DNS_API_TOKEN=${config.sops.placeholder.${secret}}
    '';
    owner = "acme";
  };

  security.acme = {
    acceptTerms = true;
    defaults.email = "mdlayher@gmail.com";

    certs.${domain} = {
      # The wildcard beneath the peering name, plus the apex mdlayher.net,
      # which has no site of its own and redirects here (see its vhost
      # below); the redirect answers on 443, so the apex must be on this
      # cert or the handshake fails before the 301 is ever sent.
      extraDomainNames = [
        "*.${domain}"
        "mdlayher.net"
      ];
      dnsProvider = "cloudflare";
      environmentFile = config.sops.templates."acme-cloudflare.env".path;
      # Readable by whatever serves it; the nginx module adds itself to
      # reloadServices for the renewal.
      group = config.services.nginx.group;
    };

    # The dn42 name's certificate: declared by the vhost below (enableACME,
    # which also wires the HTTP-01 webroot), issued by the dn42 CA. Until
    # the first order succeeds nginx serves the module's placeholder, so
    # the name is reachable over HTTPS from the first deploy either way.
    certs.${dn42.domain} = {
      server = dn42Acme;
      validMinDays = 10;
      # The page vhost's aliases join on their own; the redirect vhosts'
      # names are added here.
      extraDomainNames = map (prefix: "${prefix}azo.${dn42.domain}") ([ "" ] ++ familyPrefixes);
    };
  };

  services.nginx = {
    enable = true;
    recommendedTlsSettings = true;

    # The access log as JSON to the journal, under its own syslog identifier
    # (no dash: nginx allows only alphanumerics and underscore in a tag) so
    # it is a separate stream from the error log; alloy counts it into
    # Prometheus and ships it to Loki, see nixos/modules/alloy.nix. The
    # default is a file under /var/log/nginx that nothing reads.
    #
    # $server_name is the matched server block's configured name, bounded
    # to the two vhosts ($host is whatever the client sent). proto and
    # family are the maps in appendHttpConfig, declared later: variables
    # resolve once the whole config is parsed, but a log_format must
    # precede the access_log that names it, hence commonHttpConfig. The
    # client address is kept for forensics, never as a label; Loki keeps
    # the stream for 30 days, see nixos/servnerr-4/loki.nix.
    commonHttpConfig = ''
      log_format access escape=json
        '{"vhost":"$server_name","status":$status,"method":"$request_method",'
        '"uri":"$request_uri","proto":"$proto","family":"$tier",'
        '"tls":"$ssl_protocol","bytes":$body_bytes_sent,"request_time":$request_time,'
        '"client":"$remote_addr","user_agent":"$http_user_agent","referer":"$http_referer"}';
      access_log syslog:server=unix:/dev/log,tag=nginx_access,nohostname access;

      # Missing files are 404s in the access log now, not error log lines:
      # scanners probing the WAN address made thousands a day.
      log_not_found off;
    '';

    # The tier, from the accepted connection: see the header comment.
    # $server_addr is the address the client connected to, and nginx writes
    # IPv6 without brackets. The regex entries of a map are tried in order,
    # and an IPv6 dn42 address contains a colon too, so dn42 goes first.
    appendHttpConfig = ''
      map $server_addr $dn42 {
        default 0;
        ${dn42.addr4} 1;
        ${dn42.addr6} 1;
      }

      map "$dn42 $remote_addr" $tier {
        default ipv4;
        "~^1 " dn42;
        "~:" ipv6;
      }

      # The negotiated HTTP version as people write it. nginx reports
      # HTTP/2 and HTTP/3 with a ".0" minor that nobody else uses; HTTP/1.x
      # passes through as is.
      map $server_protocol $proto {
        default $server_protocol;
        HTTP/2.0 HTTP/2;
        HTTP/3.0 HTTP/3;
      }

      # The client's address family, cased for display.
      map $remote_addr $family {
        default IPv4;
        "~:" IPv6;
      }

      # How the client reached us, as the page says it: the version and
      # the family, the latter a dn42 one when the address it hit is.
      # Injected into the page in place of a fixed phrase, so both
      # connection facts are reported alike.
      map $dn42 $vantage {
        default "$proto over $family";
        1 "$proto over dn42 $family";
      }
    '';

    # One server for every address on 80 and 443: the public name over the
    # clearnet, and the router's dn42 addresses by number from inside dn42,
    # where no public certificate can name the destination, so plain HTTP is
    # left open rather than redirected. The certificate is the one the acme
    # block above obtains, and QUIC on UDP 443 uses it too.
    virtualHosts.${domain} = {
      default = true;
      addSSL = true;
      useACMEHost = domain;

      # HTTP/3. quic adds the UDP 443 listeners beside the TCP ones; the
      # module turns http3 on with it. No client tries QUIC first, so the
      # header tells one that arrived over TCP where to find it, for a
      # day. Clients ignore Alt-Svc on plain HTTP, and inside dn42 a
      # numeric address never matches the certificate anyway, so the
      # header is harmless where it cannot be followed.
      quic = true;
      extraConfig = ''
        add_header Alt-Svc 'h3=":443"; ma=86400';
      '';

      inherit root locations;
    };

    # The same page under our dn42 domain, which coredns.nix resolves to
    # the router's dn42 addresses for dn42: the certificate is the dn42
    # CA's, trusted by those who installed its root, and plain HTTP stays
    # open for the rest. The single-family names serve the page too, as on
    # the clearnet, and join the certificate as aliases. HTTP/3 as above:
    # the QUIC listener is shared, nginx picks the server by SNI, and the
    # zone's HTTPS records advertise h3 beside the Alt-Svc header.
    virtualHosts.${dn42.domain} = {
      addSSL = true;
      enableACME = true;
      serverAliases = map (prefix: "${prefix}${dn42.domain}") familyPrefixes;
      quic = true;
      extraConfig = ''
        add_header Alt-Svc 'h3=":443"; ma=86400';
      '';
      inherit root locations;
    };

    # azo, the router's reverse name and the site's, and the single-family
    # names beneath it are pointers to the names above: each redirects to
    # its counterpart, on the scheme it arrived by. They are on the
    # certificate too (extraDomainNames above), so HTTPS redirects as well.
    virtualHosts."azo.${dn42.domain}" = azoRedirect "";
    virtualHosts."ipv4.azo.${dn42.domain}" = azoRedirect "ipv4.";
    virtualHosts."ipv6.azo.${dn42.domain}" = azoRedirect "ipv6.";

    # The apex mdlayher.net has no site of its own: send anyone who trims
    # the name down to the registered domain to the peering page, rather
    # than a certificate mismatch against the default vhost above. Its
    # address records are the router's WANs (the ddns apex), so requests
    # arrive on the 80 and 443 already open; addSSL serves both, with the
    # certificate above (which names the apex as a SAN). Clearnet only:
    # nothing resolves the apex to a dn42 address.
    virtualHosts."mdlayher.net" = {
      addSSL = true;
      useACMEHost = domain;
      locations."/".return = "301 https://${domain}/";
    };
  };
}
