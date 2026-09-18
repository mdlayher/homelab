# The interconnect landing page, at this site's icl names.
#
# Those names are WireGuard carrier endpoints another site dials, and they
# resolve to the same WAN addresses as every other public name here, so
# without a server of their own they land on the peering page's default
# vhost: dn42's page under a name that has nothing to do with dn42, and a
# certificate that does not cover them.
#
# Two renderings as on the peering page, HTML or text by Accept, and two
# views. The public one says what the name is; the fabric one adds the
# circuits terminating here, generated from the interconnect options so it
# cannot drift from them. The view follows the address the request arrived
# on rather than the name it asked for, so the clearnet cannot reach the
# fabric one by sending a Host header. That address is this router's
# loopback, which the circuits and every segment here can reach, and which
# no certificate can name, so from the fabric this is plain HTTP.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  inventory = config.homelab.inventory;
  interconnect = config.homelab.interconnect;

  site = config.homelab.site;
  loopback = inventory.loopbacks.${config.networking.hostName};

  # The label this site's interconnect names share. It names the server
  # block, the certificate, and the vhost in the access log, so every one of
  # those names counts as one vhost there. Nothing resolves it, which a
  # DNS-01 order does not need: the challenge is a TXT record beneath it.
  label = "${site}.icl.mdlayher.net";

  # The names themselves: the two a far site dials, and the per-uplink names
  # they alias. cloudflare-ddns.nix publishes the per-uplink ones and
  # terraform/cloudflare declares the aliases; this is the same set seen from
  # the server that has to answer for them.
  names = map (prefix: "${prefix}.${site}.icl.mdlayher.net") [
    "ipv4"
    "ipv6"
    "ipv4.spectrum"
    "ipv6.spectrum"
    "ipv4.metronet"
  ];

  pad = n: s: s + lib.concatStrings (lib.genList (_: " ") (lib.max 0 (n - lib.stringLength s)));

  # What the fabric view shows, as key/value pairs, so the two renderings
  # cannot disagree about any of it.
  siteFacts = [
    {
      k = "loopback";
      v = loopback.addr;
    }
    {
      k = "IS-IS";
      v = interconnect.isis.net;
    }
    {
      k = "advertises";
      v = interconnect.isis.aggregate;
    }
  ];

  circuitFacts = link: [
    {
      k = "far site";
      v = "${link.site}, plane ${toString link.plane}";
    }
    {
      k = "carrier";
      v = "${link.carrier}, udp ${toString link.port}, mtu ${toString link.carrierMtu}";
    }
    {
      k = "circuit";
      v = "mtu ${toString link.mtu}";
    }
    {
      k = "carrier addresses";
      v = "${link.localAddress} to ${link.remoteAddress}";
    }
    {
      k = "circuit address";
      v = link.localCircuitAddress;
    }
    {
      k = "endpoint";
      v = if link.endpoint == null then "none, the far site initiates" else link.endpoint;
    }
  ];

  # Section title, then facts, once per circuit and keyed by the interface
  # the IGP names.
  sections = [
    {
      title = "Site";
      facts = siteFacts;
    }
  ]
  ++ map (link: {
    title = link.interface;
    facts = circuitFacts link;
  }) (lib.attrValues interconnect.links);

  # The phrase nginx rewrites per request, from the $vantage map in
  # dn42-page.nix: the file reads sensibly on its own and the response names
  # the HTTP version and address family the request actually arrived over.
  vantage = "Reached via HTTP over IP.";

  intro = "This name is a carrier endpoint.";

  title = "${site}: site interconnect";

  text =
    fabric:
    ''
      ${title}
      ${lib.concatStrings (lib.genList (_: "=") (lib.stringLength title))}

      ${intro}
      ${vantage}
    ''
    + lib.optionalString fabric (
      lib.concatMapStrings (s: ''

        ${s.title}
        ${lib.concatMapStrings (f: "  ${pad 19 f.k}${f.v}\n") s.facts}'') sections
    );

  html =
    fabric:
    ''
      <!DOCTYPE html>
      <html lang="en">
      <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>${title}</title>
      <style>
      :root { --bg: #f7f7f2; --fg: #222; --muted: #666; --rule: #ddd; --link: #1a5fb4; }
      @media (prefers-color-scheme: dark) {
        :root { --bg: #15171c; --fg: #e4e6eb; --muted: #9aa0ab; --rule: #33373f; --link: #8ab4ff; }
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
      h2 { font-size: 1.15rem; margin: 2rem 0 .5rem; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
      p { margin: .5rem 0; }
      a { color: var(--link); }
      .vantage { color: var(--muted); }
      table { border-collapse: collapse; width: 100%; }
      th, td { text-align: left; vertical-align: top; padding: .35rem .5rem; border-bottom: 1px solid var(--rule); }
      th { white-space: nowrap; font-weight: 600; width: 11rem; }
      td { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: .95em; overflow-wrap: anywhere; }
      </style>
      </head>
      <body>
      <h1>${site} <small>site interconnect</small></h1>
      <p>${intro}</p>
      <p class="vantage">${vantage}</p>
    ''
    + lib.optionalString fabric (
      lib.concatMapStrings (s: ''
        <h2>${s.title}</h2>
        <table>
        ${lib.concatMapStrings (f: "<tr><th>${f.k}</th><td>${f.v}</td></tr>\n") s.facts}</table>
      '') sections
    )
    + ''
      </body>
      </html>
    '';

  root = pkgs.runCommand "icl-page" { } ''
    install -Dm444 ${pkgs.writeText "public.html" (html false)} $out/public.html
    install -Dm444 ${pkgs.writeText "public.txt" (text false)} $out/public.txt
    install -Dm444 ${pkgs.writeText "fabric.html" (html true)} $out/fabric.html
    install -Dm444 ${pkgs.writeText "fabric.txt" (text true)} $out/fabric.txt
  '';
in
{
  # Its own order rather than more names on the peering page's certificate:
  # an order fails as a unit, so one name failing validation here would stop
  # that certificate renewing too. DNS-01 rather than HTTP-01 because three
  # of these names are pinned to one uplink each, and HTTP-01 would fail to
  # renew whenever that uplink was down. The credential is the one
  # dn42-page.nix renders for the same provider.
  security.acme.certs.${label} = {
    extraDomainNames = names;
    dnsProvider = "cloudflare";
    environmentFile = config.sops.templates."acme-cloudflare.env".path;
    group = config.services.nginx.group;
  };

  services.nginx = {
    # Which view a request gets, from the address it reached rather than the
    # name it asked for, and which rendering, from Accept as on the peering
    # page. The two compose into the file name.
    appendHttpConfig = ''
      map $server_addr $icl_view {
        default public;
        ${loopback.addr} fabric;
      }

      map $http_accept $icl_type {
        default txt;
        "~*text/html" html;
      }
    '';

    virtualHosts.${label} = {
      addSSL = true;
      useACMEHost = label;
      # The loopback by name, which this site's resolver answers, and by
      # number, which is all a client across a circuit has. Neither can be
      # on the certificate: one is an internal name and the other an
      # address, so the fabric view is plain HTTP.
      serverAliases =
        names
        ++ lib.optional (loopback.fqdn != null) loopback.fqdn
        ++ [
          "[${loopback.addr}]"
        ];

      inherit root;

      locations."= /".extraConfig = ''
        try_files /$icl_view.$icl_type =404;
        charset utf-8;
        sub_filter 'via HTTP over IP' 'via $vantage';
        sub_filter_once on;
        sub_filter_types text/plain;
        add_header Vary Accept;
      '';
    };
  };
}
