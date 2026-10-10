# The router's nftables firewall under test: its ruleset, verbatim, loaded
# into a network namespace inside the build sandbox, with a namespace for
# each thing the router faces and probes sent between them (see run.sh,
# topology.sh and cases.nix). Run by nix flake check.
#
# The set elements are the router's own sops template with made-up values
# in place of every inventory secret: each host gets an address inside its
# segment's prefix and a MAC built from the VLAN, so nothing from
# secrets.yaml is read and the elements keep the exact shape the router
# renders.
{
  pkgs,
  lib,
  inventory,
  nixosConfigurations,
}:

let
  router = nixosConfigurations.${lib.head inventory.roles.router}.config;
  server = nixosConfigurations.${lib.head inventory.roles.server}.config;
  inv = router.homelab.inventory;
  routerName = router.networking.hostName;
  dn42 = router.homelab.dn42;

  hex = n: lib.toLower (lib.toHexString n);
  hex2 = n: lib.fixedWidthString 2 "0" (hex n);
  ipv4Plus =
    a: n:
    let
      octets = lib.splitString "." a;
    in
    lib.concatStringsSep "." (lib.take 3 octets ++ [ (toString (lib.toInt (lib.last octets) + n)) ]);

  # Made-up values for each inventory host, numbered within its segment.
  hosts = lib.listToAttrs (
    lib.concatMap (
      ifi:
      lib.imap1 (
        i: h:
        let
          iid = "200:0:0:${hex (100 + i)}";
        in
        lib.nameValuePair h.name {
          inherit (h) interface;
          inherit iid;
          ipv4 = "${ifi.ipv4Prefix}.${toString (100 + i)}";
          ula = if h.ula == null then null else "${ifi.ulaPrefix}:${iid}";
          mac = "02:00:00:00:${hex2 ifi.vlan}:${hex2 i}";
        }
      ) ifi.hosts
    ) (lib.attrValues inv.interfaces)
  );

  secretValues = lib.concatMapAttrs (name: h: {
    "inventory/hosts/${name}/ipv4" = h.ipv4;
    "inventory/hosts/${name}/mac" = h.mac;
    "inventory/hosts/${name}/iid" = h.iid;
    "inventory/hosts/${name}/iid_ula" = h.iid;
  }) hosts;
  placeholders = lib.filterAttrs (name: _: secretValues ? ${name}) router.sops.placeholder;
  template = router.sops.templates."nftables-inventory.conf".content;
  substituted = builtins.replaceStrings (lib.attrValues placeholders) (lib.attrValues (
    lib.intersectAttrs placeholders secretValues
  )) template;

  # A host the router denies the internet, by MAC, whether or not the
  # inventory holds one, so the drop is exercised either way: the client
  # on this segment carries the MAC.
  denied = rec {
    ifname = "iot0";
    mac = "02:00:00:00:de:01";
    ipv4 = "${inv.interfaces.${ifname}.ipv4Prefix}.10";
  };

  elements = pkgs.writeText "router-firewall-elements.nft" (
    assert lib.assertMsg (
      !lib.hasInfix "<SOPS:" substituted
    ) "router-firewall: the router's nftables template holds a secret the test has no value for";
    ''
      ${substituted}
      add element inet filter wan_denied { ${denied.mac} }
    ''
  );

  # The tables render beside the ruleset the way the NixOS module writes
  # them, ahead of it.
  routerNftables = router.networking.nftables;
  ruleset = pkgs.writeText "router-firewall-ruleset.nft" ''
    ${lib.concatMapStrings (t: ''
      table ${t.family} ${t.name} {
        ${t.content}
      }
    '') (lib.filter (t: t.enable) (lib.attrValues routerNftables.tables))}
    ${routerNftables.ruleset}
  '';

  # What each namespace's input hook admitted, by protocol and port; see
  # run.sh.
  sink = pkgs.writeText "router-firewall-sink.nft" ''
    table inet sink {
      set seen {
        type inet_proto . inet_service
        flags dynamic
      }
      chain input {
        type filter hook input priority 100; policy accept;
        meta l4proto { tcp, udp } add @seen { meta l4proto . th dport }
      }
    }
  '';

  # The network outside the inventory, from the documentation and
  # benchmarking ranges where it stands for the internet.
  net = {
    wan0 = {
      router4 = "192.0.2.1";
      peer4 = "192.0.2.2";
      router6 = "2001:db8:0:1::1";
      peer6 = "2001:db8:0:1::2";
    };
    wan1 = {
      router4 = "198.51.100.1";
      peer4 = "198.51.100.2";
      router6 = "2001:db8:0:2::1";
      peer6 = "2001:db8:0:2::2";
    };
    ts0 = {
      router4 = "100.64.0.1";
      peer4 = "100.64.0.2";
      router6 = "fd7a:115c:a1e0::1";
      peer6 = "fd7a:115c:a1e0::2";
    };
    # An interface matching no class the ruleset names.
    unclassified = {
      ifname = "unclassified0";
      router4 = "198.18.0.1";
      peer4 = "198.18.0.2";
      router6 = "2001:db8:0:3::1";
      peer6 = "2001:db8:0:3::2";
    };
    # A source outside both our space and dn42's.
    foreign4 = "203.0.113.9";
    foreign6 = "2001:db8:0:9::9";
  };

  # An external dn42 peer on its tunnel, holding dn42 space that is not
  # ours, reached over link-local next hops as the tunnels are.
  peer = {
    ifname = "dn42e-test";
    routerLla = dn42.lla;
    lla = (lib.head (lib.attrValues dn42.peers)).lla;
    ipv4 = "172.20.50.1";
    ipv6 = "fd42:4242:50::1";
    prefix4 = "172.20.50.0/24";
    prefix6 = "fd42:4242:50::/48";
  };

  # One of our own dn42 hosts on the first internal VLAN.
  dn42Vlan = lib.head (lib.attrValues dn42.vlans);
  dn42Host = {
    ifname = "dn42i-test";
    router4 = "${dn42.addr4}/${lib.last (lib.splitString "/" dn42Vlan.onLink4)}";
    router6 = "${dn42Vlan.addr6}/64";
    ipv4 = ipv4Plus (lib.head (lib.splitString "/" dn42Vlan.onLink4)) 2;
    ipv6 = dn42Vlan.neighbor;
  };

  # The first edge's site across a circuit: its loopbacks, our dn42
  # loopback there, and a host in the site's prefix, on a link addressed
  # from the circuit prefixes the way the module numbers a pair of sites.
  edgeName = lib.head inv.roles.edge;
  routerSite = inv.sites.${router.homelab.site};
  farSite = lib.findFirst (
    s: s.loopbacks ? ${edgeName}
  ) (throw "router-firewall: no site holds ${edgeName}") (lib.attrValues inv.sites);
  pair = "${toString routerSite.index}${toString farSite.index}";
  far = {
    ifname = "icl-test0";
    router6 = "${lib.removeSuffix "00::/56" inv.circuitPrefix6}${pair}::2";
    peer6 = "${lib.removeSuffix "00::/56" inv.circuitPrefix6}${pair}::3";
    router4 = "${lib.removeSuffix "0.0/16" inv.circuitPrefix4}${pair}.2";
    peer4 = "${lib.removeSuffix "0.0/16" inv.circuitPrefix4}${pair}.3";
    lo6 = farSite.loopbacks.${edgeName}.addr6;
    lo4 = farSite.loopbacks.${edgeName}.addr4;
    dn42v6 = inv.dn42.loopbacks.${edgeName}.addr6;
    dn42v4 = inv.dn42.loopbacks.${edgeName}.addr4;
    host6 = "${lib.removeSuffix "::/56" farSite.prefix6}::10";
    host4 = ipv4Plus (lib.head (lib.splitString "/" farSite.prefix4)) 10;
  };

  # The first remote access device and the router's end of its tunnel.
  device = lib.head (lib.attrValues router.homelab.remoteAccess.devices);
  remote = {
    ifname = router.homelab.remoteAccess.interface;
    inherit device;
    router6 = "${lib.head (lib.splitString "::" device.address)}::1";
  };

  # The router's addresses on lo.
  routerLo = lib.unique [
    "${inv.loopbacks.${routerName}.addr4}/32"
    "${inv.loopbacks.${routerName}.addr6}/128"
    "${inv.anycast4.dns}/32"
    "${inv.anycast4.ntp}/32"
    "${inv.anycast6.dns}/128"
    "${inv.anycast6.ntp}/128"
    "${dn42.addr6}/128"
    "${inv.dn42.loopbacks.${routerName}.addr4}/32"
    "${inv.dn42.loopbacks.${routerName}.addr6}/128"
  ];

  # Multicast groups the router listens for on each restricted LAN: MLDv2
  # reports, SSDP and mDNS.
  groups = [
    "ff02::16"
    "ff02::c"
    "ff02::fb"
    "239.255.255.250"
    "224.0.0.251"
  ];

  f = {
    inherit
      inv
      hosts
      denied
      net
      peer
      dn42Host
      far
      remote
      ;
    dn42 = {
      inherit (dn42) addr4 addr6;
      loopback4 = inv.dn42.loopbacks.${routerName}.addr4;
      loopback6 = inv.dn42.loopbacks.${routerName}.addr6;
    };
    # An address in our dn42 allocation that no namespace holds, for a
    # peer to forge.
    ourDn42 = {
      v4 = ipv4Plus (lib.head (lib.splitString "/" inv.dn42.net4)) 14;
      v6 = "${lib.removeSuffix "::/48" inv.dn42.net6}:ffff::1";
    };
    # The address each namespace sends from when a case names none.
    sources =
      lib.mapAttrs (_: ifi: {
        v4 = "${ifi.ipv4Prefix}.10";
        v6 = "${ifi.ulaPrefix}::10";
      }) inv.interfaces
      // {
        internet = {
          v4 = net.wan0.peer4;
          v6 = net.wan0.peer6;
        };
        tailnet = {
          v4 = net.ts0.peer4;
          v6 = net.ts0.peer6;
        };
        remote.v6 = device.address;
        dn42peer = {
          v4 = peer.ipv4;
          v6 = peer.ipv6;
        };
        dn42host = {
          v4 = dn42Host.ipv4;
          v6 = dn42Host.ipv6;
        };
        far = {
          v4 = far.host4;
          v6 = far.host6;
        };
        unclassified = {
          v4 = net.unclassified.peer4;
          v6 = net.unclassified.peer6;
        };
      };
    server = hosts.${lib.head inv.roles.server};
    lokiPort = server.services.loki.configuration.server.http_listen_port;
    lgtv = import ../../../lgtv/hosts.nix;
  };
  cases = import ./cases.nix { inherit lib f; };

  # Addresses each namespace holds from the plan below; a case's source
  # outside them is added to its namespace before the cases run, and
  # becomes local there like the rest.
  segmentAddrs =
    ifi:
    [
      "${ifi.ipv4Prefix}.10"
      "${ifi.ulaPrefix}::10"
    ]
    ++ lib.concatMap (h: [ h.ipv4 ] ++ lib.optional (h.ula != null) h.ula) (
      map (h: hosts.${h.name}) ifi.hosts
    );
  held = lib.mapAttrs (_: segmentAddrs) inv.interfaces // {
    dn42peer = [
      peer.ipv4
      peer.ipv6
    ];
    far = [
      far.peer6
      far.peer4
      far.lo6
      far.lo4
      far.dn42v6
      far.dn42v4
      far.host6
      far.host4
    ];
    internet = [
      net.wan0.peer4
      net.wan0.peer6
    ];
    tailnet = [
      net.ts0.peer4
      net.ts0.peer6
    ];
    remote = [ device.address ];
    dn42host = [
      dn42Host.ipv4
      dn42Host.ipv6
    ];
    unclassified = [
      net.unclassified.peer4
      net.unclassified.peer6
    ];
  };
  sources = lib.unique (
    map (c: { inherit (c) from src; }) (
      lib.filter (c: c.src != null && !(lib.elem c.src held.${c.from})) cases
    )
  );
  local = ns: held.${ns} ++ map (x: x.src) (lib.filter (x: x.from == ns) sources);

  # A destination local to the sending namespace never leaves it, and a
  # source local to the receiving one is a martian there, so no case may
  # rely on either.
  collisions = lib.filter (
    c:
    (c.from != "router" && lib.elem c.dst (local c.from))
    || (c.to != "router" && c.src != null && lib.elem c.src (local c.to))
  ) cases;
  hold = c: "addr ${c.from} eth0 ${c.src}/${if lib.hasInfix ":" c.src then "128" else "32"}";

  sh = lib.escapeShellArgs;
  plan = pkgs.writeText "router-firewall-plan.sh" (
    assert lib.assertMsg (collisions == [ ])
      "router-firewall: cases send to or from an address local to the other end: ${
        lib.concatMapStringsSep ", " (c: c.name) collisions
      }";
    ''
      router ${sh routerLo}

      link wan0 internet ${
        sh [
          "${net.wan0.router4}/24 ${net.wan0.router6}/64"
          "${net.wan0.peer4}/24 ${net.wan0.peer6}/64"
        ]
      }
      route router ${net.wan0.peer4} wan0 default4
      route router ${net.wan0.peer6} wan0 default6
      route internet ${net.wan0.router4} eth0 default4
      route internet ${net.wan0.router6} eth0 default6
      link wan1 internet1 ${
        sh [
          "${net.wan1.router4}/24 ${net.wan1.router6}/64"
          "${net.wan1.peer4}/24 ${net.wan1.peer6}/64"
        ]
      }

      ${lib.concatMapStrings (ifi: ''
        segment ${ifi.name} ${ifi.ipv4Prefix} ${ifi.ulaPrefix} ${ifi.lla}
        addr ${ifi.name} eth0 ${
          sh (map (a: if lib.hasInfix ":" a then "${a}/64" else "${a}/24") (lib.drop 2 (segmentAddrs ifi)))
        }
        ${lib.optionalString (!ifi.trusted) "join ${ifi.name} ${sh groups}"}
      '') (lib.attrValues inv.interfaces)}
      mac ${denied.ifname} ${denied.mac}

      link ts0 tailnet ${
        sh [
          "${net.ts0.router4}/10 ${net.ts0.router6}/48"
          "${net.ts0.peer4}/10 ${net.ts0.peer6}/48"
        ]
      }
      route tailnet ${net.ts0.router4} eth0 default4
      route tailnet ${net.ts0.router6} eth0 default6

      link ${remote.ifname} remote ${
        sh [
          "${remote.router6}/64"
          "${device.address}/64"
        ]
      }
      route remote ${remote.router6} eth0 default6

      link ${peer.ifname} dn42peer ${
        sh [
          "${peer.routerLla}/64"
          "${peer.lla}/64 ${peer.ipv4}/32 ${peer.ipv6}/128"
        ]
      }
      route router ${peer.lla} ${peer.ifname} ${peer.prefix4} ${peer.prefix6}
      route dn42peer ${peer.routerLla} eth0 default4 default6

      link ${dn42Host.ifname} dn42host ${
        sh [
          "${dn42Host.router4} ${dn42Host.router6}"
          "${dn42Host.ipv4}/29 ${dn42Host.ipv6}/64"
        ]
      }
      route dn42host ${dn42.addr4} eth0 default4
      route dn42host ${dn42Vlan.addr6} eth0 default6

      link ${far.ifname} far ${
        sh [
          "${far.router6}/127 ${far.router4}/31"
          "${far.peer6}/127 ${far.peer4}/31 ${far.lo6}/128 ${far.lo4}/32 ${far.dn42v6}/128 ${far.dn42v4}/32 ${far.host6}/128 ${far.host4}/32"
        ]
      }
      route router ${far.peer6} ${far.ifname} ${farSite.prefix6} ${far.lo6}/128 ${far.dn42v6}/128
      route router ${far.peer4} ${far.ifname} ${farSite.prefix4} ${far.lo4}/32 ${far.dn42v4}/32
      route far ${far.router6} eth0 default6
      route far ${far.router4} eth0 default4

      link ${net.unclassified.ifname} unclassified ${
        sh [
          "${net.unclassified.router4}/24 ${net.unclassified.router6}/64"
          "${net.unclassified.peer4}/24 ${net.unclassified.peer6}/64"
        ]
      }

      ${lib.concatMapStringsSep "\n" hold sources}
    ''
  );

  # One line per case for run.sh, tab-separated; "-" for an empty field.
  field = v: if v == null then "-" else toString v;
  caseTable = pkgs.writeText "router-firewall-cases.tsv" (
    lib.concatMapStrings (
      c:
      lib.concatMapStringsSep "\t" field [
        c.name
        c.from
        c.to
        c.src
        c.dst
        c.probe
        c.port
        c.sport
        c.verdict
        c.what
      ]
      + "\n"
    ) cases
  );
in
pkgs.runCommand "router-firewall"
  {
    nativeBuildInputs = with pkgs; [
      iproute2
      iputils
      jq
      netcat-openbsd
      nftables
      procps
      python3Minimal
      shellcheck
      util-linux
    ];
    env = {
      TOPOLOGY = "${./topology.sh}";
      PLAN = plan;
      RULESET = ruleset;
      ELEMENTS = elements;
      SINK = sink;
      CASES = caseTable;
      PACKET = "${./packet.py}";
    };
  }
  ''
    shellcheck --external-sources --source-path=${./.} ${./run.sh} ${./topology.sh}
    # The namespaces the cases need are created under this one; a failure
    # to create any of them fails the check. The router resolves protocol
    # names in its ruleset through /etc/protocols, which the sandbox
    # lacks, so this mount namespace sees iana-etc's as the router does.
    mkdir etc
    cp -r /etc/. etc/
    cp ${pkgs.iana-etc}/etc/protocols etc/protocols
    unshare --user --map-root-user --net --mount bash -c 'mount --bind etc /etc && exec bash ${./run.sh}'

    touch $out
  ''
