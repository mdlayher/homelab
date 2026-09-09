# The dn42 Peer Finder measurement agent, https://peerfinder.dn42.dev: the
# peerfinder backend connects to this agent and asks it to ping candidate
# peers, so the site can rank them by latency from our network. It runs on
# the router, the host with the dn42 presence (see dn42.nix) and the WAN
# address recorded at registration, which is where the backend connects
# from the clearnet. Should the WAN address change, the registration must
# be updated by hand; the backend uses the address it was given, not a name.
#
# The agent is kioubit's peerfinder-agent.py, vendored beside this file
# unmodified. It is standard-library Python, so it runs straight from the
# store with no packaging. Every request carries an HMAC over the shared
# secret from registration with a nonce cache and a 30 s timestamp window,
# so only the backend can make it ping anything; targets are validated as
# IP addresses before ping is spawned. The listener binds every address;
# nftables.nix admits the port from the internet, rate limited, and from
# the trusted LANs as any router service.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.homelab.dn42.peerfinder;
in
{
  options.homelab.dn42.peerfinder.port = lib.mkOption {
    type = lib.types.port;
    default = 9000;
    description = ''
      TCP port the peerfinder agent listens on, as recorded at
      registration. Opened on the WANs in nftables.nix.
    '';
  };

  config = {
    # The registration secret: 32 bytes as 64 hex characters, which the
    # agent checks at startup and exits on otherwise.
    sops.secrets."dn42/peerfinder_key" = {
      sopsFile = ./secrets.yaml;
      restartUnits = [ "peerfinder-agent.service" ];
    };

    # The upstream recommended unit, translated. Restart slowly: the backend
    # tolerates an agent being away, and a bad key would otherwise loop.
    systemd.services.peerfinder-agent = {
      description = "dn42 Peer Finder measurement agent";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];

      # The agent shells out to ping, found via the service PATH. This is
      # the plain iputils binary, not the setuid wrapper, which
      # NoNewPrivileges would neuter anyway.
      path = [ pkgs.iputils ];

      environment = {
        SECRET_KEY_FILE = "%d/SECRET_KEY_FILE";
        LISTEN_PORT = toString cfg.port;
      };

      serviceConfig = {
        ExecStart = "${pkgs.python3}/bin/python3 ${./peerfinder-agent.py}";
        Restart = "always";
        RestartSec = "300s";

        # The agent runs with DynamicUser, so hand it the key via a systemd
        # credential rather than a file owned by a static user.
        LoadCredential = "SECRET_KEY_FILE:${config.sops.secrets."dn42/peerfinder_key".path}";

        # ping opens an ICMP socket: an unprivileged datagram one on this
        # machine, where every group may, with a raw socket as fallback.
        # CAP_NET_RAW covers the fallback and must be granted in both
        # places, since systemd intersects the ambient set with the
        # bounding set; ambient capabilities survive exec into the ping
        # child. Everything else is locked down; the agent is stateless
        # and writes nothing.
        DynamicUser = true;
        AmbientCapabilities = [ "CAP_NET_RAW" ];
        CapabilityBoundingSet = [ "CAP_NET_RAW" ];
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        ProtectKernelTunables = true;
        ProtectControlGroups = true;
        RestrictNamespaces = true;
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
        ];
        SystemCallArchitectures = "native";
        MemoryDenyWriteExecute = true;
        # The agent's thread pool plus one ping child per worker.
        TasksMax = 20;
      };
    };
  };
}
