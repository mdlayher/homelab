# The dn42 peering page, https://azo.dn42.mdlayher.net: what a prospective
# peer needs to set up a session, generated from the dn42.nix options so it
# cannot drift from the tunnels and bird.
#
# Served from the router, the one host with both a WAN and a dn42 address,
# so it answers from the clearnet and from inside dn42 without NAT in the
# way. The page names how the client reached it (IPv4, IPv6, or dn42) from
# the accepted connection: a connection to one of the router's dn42
# addresses came through dn42, since those addresses exist nowhere else;
# anything else is the client's address family.
#
# v1 is static. The fixed points for a later server to drop into are the
# certificate under /var/lib/acme/<domain>/, which the acme module renews
# on its own, and ports 80 and 443 on every address.
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

  # The vantage tiers, and the HTML file each is served from.
  tiers = [
    "ipv4"
    "ipv6"
    "dn42"
  ];

  # The page for one tier: the same page with one line naming the tier. No
  # scripts and nothing fetched, so each is a single self-contained file.
  page =
    tier:
    let
      vantage =
        {
          ipv4 = "IPv4";
          ipv6 = "IPv6";
          dn42 = "dn42";
        }
        .${tier};

      peerRows = lib.concatStrings (
        lib.mapAttrsToList (name: peer: ''
          <tr><td>${name}</td><td>AS${toString peer.asn}</td><td>${toString peer.port}</td></tr>
        '') dn42.peers
      );
    in
    ''
      <!DOCTYPE html>
      <html lang="en" class="tier-${tier}">
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
      <p class="vantage">Connected over ${vantage}.</p>

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
          <a href="http://${dn42.addr4}/"><code>http://${dn42.addr4}/</code></a><br>
          <a href="http://[${dn42.addr6}]/"><code>http://[${dn42.addr6}]/</code></a>
        </p>
      </footer>
      </body>
      </html>
    '';

  # One file per tier; nginx picks by the tier it decided for the
  # connection.
  root = pkgs.runCommand "azo-page" { } (
    lib.concatMapStrings (tier: ''
      install -Dm444 ${pkgs.writeText "${tier}.html" (page tier)} $out/${tier}.html
    '') tiers
  );
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
  };

  services.nginx = {
    enable = true;
    recommendedTlsSettings = true;

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
    '';

    # One server for every address on 80 and 443: the public name over the
    # clearnet, and the router's dn42 addresses by number from inside dn42,
    # where no public certificate can name the destination, so plain HTTP is
    # left open rather than redirected. The certificate is the one the acme
    # block above obtains.
    virtualHosts.${domain} = {
      default = true;
      addSSL = true;
      useACMEHost = domain;

      inherit root;
      locations."= /".extraConfig = ''
        try_files /$tier.html =404;
      '';
    };

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
