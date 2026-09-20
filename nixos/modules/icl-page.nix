# The interconnect landing page, at a site's icl names.
#
# Those names are WireGuard carrier endpoints another site dials. Where a
# site serves anything else on the same addresses they would land on its
# default vhost, under a certificate that does not cover them; where it
# serves nothing else, they answer nothing at all.
#
# Two renderings, HTML or text by Accept, and two views. The public one says
# what the name is; the fabric one adds the circuits terminating here,
# generated from the interconnect options so it cannot drift from them. The
# view follows the address the request arrived on rather than the name it
# asked for, so the clearnet cannot reach the fabric one by sending a Host
# header. That address is this site's loopback, which the circuits and every
# segment here can reach, and which no certificate can name, so the fabric
# view is plain HTTP.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  inventory = config.homelab.inventory;
  interconnect = config.homelab.interconnect;
  cfg = interconnect.page;

  site = config.homelab.site;
  loopback = inventory.loopbacks.${config.networking.hostName} or null;

  # The public zone. A literal rather than the inventory's, which names the
  # zone a router serves internally: the two share a string and nothing else.
  zone = "mdlayher.net";

  # The label this site's interconnect names share. It names the server
  # block, the certificate's state directory, and the vhost in the access
  # log, so every one of those names counts as one vhost there. Nothing
  # resolves it, which is why it is not the certificate's own domain.
  label = "${site}.icl.${zone}";

  # The two names a far site dials, which every site has, and whatever else
  # this one answers for beneath the same label.
  dial = family: "${family}.${site}.icl.${zone}";
  names = [
    (dial "ipv4")
    (dial "ipv6")
  ]
  ++ cfg.extraNames;

  # HTTP-01's challenge directory, used when no DNS credential is given.
  webroot = "/var/lib/acme/acme-challenge";

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
  ]
  ++ lib.optional (interconnect.isis.aggregate != null) {
    k = "advertises";
    v = interconnect.isis.aggregate;
  };

  circuitFacts =
    link:
    [
      {
        k = "far end";
        v = if link.site == site then "this site" else "${link.site}, plane ${toString link.plane}";
      }
    ]
    # A link whose ends share a segment is built straight on their addresses
    # and has no carrier to describe.
    ++ lib.optional (link.carrier != null) {
      k = "carrier";
      v = "${link.carrier}, udp ${toString link.port}, mtu ${toString link.carrierMtu}";
    }
    ++ [
      {
        k = "circuit";
        v = "mtu ${toString link.mtu}";
      }
      {
        k = if link.carrier == null then "link addresses" else "carrier addresses";
        v = "${link.localAddress} to ${link.remoteAddress}";
      }
      {
        k = "circuit address";
        v = link.localCircuitAddress;
      }
    ]
    # An endpoint is a carrier's; a link built straight on two addresses
    # already on one segment dials nothing.
    ++ lib.optional (link.carrier != null) {
      k = "endpoint";
      v = if link.endpoint == null then "none, the far site initiates" else link.endpoint;
    };

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

  # The phrase nginx rewrites per request, from the maps below: the file
  # reads sensibly on its own and the response names the HTTP version and
  # address family the request actually arrived over.
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
  options.homelab.interconnect.page = {
    enable = lib.mkEnableOption "the interconnect landing page at this site's icl names";

    extraNames = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Further public names beneath this site's icl label, beyond the two a
        far site dials. A site whose addresses are dynamic publishes one per
        uplink and aliases the dial names to them, and those answer here too.
      '';
    };

    acmeEnvironmentFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Credential for a DNS-01 order against Cloudflare. Null orders over
        HTTP-01 instead, which needs no credential on the machine and is
        what a site with one uplink should use; a site whose names are
        pinned to an uplink each needs DNS-01, since HTTP-01 cannot validate
        a name whose uplink is down.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = loopback != null;
        message = "homelab.interconnect.page: this machine has no loopback in the inventory, and the page is served on it";
      }
    ];

    # Its own order rather than more names on another page's certificate: an
    # order fails as a unit, so one name failing validation here would stop
    # that one renewing too. The domain is a name that resolves, because the
    # server discovers HTTPS probe targets from these certificates (see
    # nixos/servnerr-4/prometheus.nix) and the label above does not.
    security.acme = {
      acceptTerms = true;
      defaults.email = lib.mkDefault "mdlayher@gmail.com";

      certs.${label} = {
        domain = dial "ipv6";
        extraDomainNames = [ (dial "ipv4") ] ++ cfg.extraNames;
        group = config.services.nginx.group;
      }
      // (
        if cfg.acmeEnvironmentFile == null then
          { inherit webroot; }
        else
          {
            dnsProvider = "cloudflare";
            environmentFile = cfg.acmeEnvironmentFile;
          }
      );
    };

    services.nginx = {
      enable = true;

      # Which view a request gets, from the address it reached rather than
      # the name it asked for, and which rendering, from Accept. The two
      # compose into the file name. The other two name the connection for
      # the page, under their own names so a machine which also serves a
      # page of its own keeps both sets.
      appendHttpConfig = ''
        map $server_addr $icl_view {
          default public;
          ${loopback.addr} fabric;
        }

        map $http_accept $icl_type {
          default txt;
          "~*text/html" html;
        }

        map $server_protocol $icl_proto {
          default $server_protocol;
          HTTP/2.0 HTTP/2;
          HTTP/3.0 HTTP/3;
        }

        map $remote_addr $icl_family {
          default IPv4;
          "~:" IPv6;
        }
      '';

      virtualHosts.${label} = {
        addSSL = true;
        useACMEHost = label;

        # The loopback by the name every site's carries, by the machine's own
        # where it has one, and by number, which is all a client across a
        # circuit has. None can be on the certificate: two are internal names
        # and one an address, so the fabric view is plain HTTP.
        serverAliases =
          names
          ++ [ loopback.siteFqdn ]
          ++ lib.optional (loopback.fqdn != null) loopback.fqdn
          ++ [ "[${loopback.addr}]" ];

        inherit root;

        # The challenge location an HTTP-01 order needs is the nginx
        # module's own, added for any vhost naming a certificate.
        locations."= /".extraConfig = ''
          try_files /$icl_view.$icl_type =404;
          charset utf-8;
          sub_filter 'via HTTP over IP' 'via $icl_proto over $icl_family';
          sub_filter_once on;
          sub_filter_types text/plain;
          add_header Vary Accept;
        '';
      };
    };
  };
}
