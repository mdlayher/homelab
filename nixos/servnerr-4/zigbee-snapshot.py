"""Samples the Zigbee mesh from Home Assistant's ZHA integration.

usage: zigbee-snapshot <url> <token file> <prom file>

One zha/devices call over Home Assistant's websocket, which reads ZHA's
cached device, neighbor and route tables and sends nothing over the radio,
then one attribute read per smart plug for its relay, which does.
Prints one JSON line per device, link and route for Loki, and writes the
device, link and relay metrics for node_exporter's textfile collector.
With <url> "-", reads a saved zha/devices result from <token file> instead
and skips the relay reads.
"""

import base64
import json
import os
import socket
import struct
import sys
from urllib.parse import urlparse


def connect(url, token):
    """Opens an authenticated websocket session to Home Assistant and
    returns a function that sends one command and returns its reply."""
    u = urlparse(url)
    s = socket.create_connection((u.hostname, u.port or 80), timeout=30)
    key = base64.b64encode(os.urandom(16)).decode()
    s.sendall(
        (
            f"GET /api/websocket HTTP/1.1\r\nHost: {u.netloc}\r\n"
            "Upgrade: websocket\r\nConnection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n"
        ).encode()
    )
    f = s.makefile("rb")
    status = f.readline()
    if b" 101 " not in status:
        sys.exit(f"websocket upgrade failed: {status!r}")
    while f.readline() not in (b"\r\n", b""):
        pass

    def recv():
        b0, b1 = f.read(2)
        n = b1 & 0x7F
        if n == 126:
            n = struct.unpack(">H", f.read(2))[0]
        elif n == 127:
            n = struct.unpack(">Q", f.read(8))[0]
        # Home Assistant sends every message as a single text frame.
        if b0 != 0x81:
            sys.exit(f"unexpected websocket frame {b0:#x}")
        return json.loads(f.read(n))

    def send(obj):
        d = json.dumps(obj).encode()
        m = os.urandom(4)
        n = len(d)
        if n < 126:
            hdr = bytes([0x81, 0x80 | n])
        elif n < 65536:
            hdr = bytes([0x81, 0x80 | 126]) + struct.pack(">H", n)
        else:
            hdr = bytes([0x81, 0x80 | 127]) + struct.pack(">Q", n)
        s.sendall(hdr + m + bytes(b ^ m[i % 4] for i, b in enumerate(d)))

    recv()
    send({"type": "auth", "access_token": token})
    r = recv()
    if r.get("type") != "auth_ok":
        sys.exit(f"auth failed: {r.get('message', r.get('type'))}")

    ids = iter(range(1, 1 << 30))

    def call(msg):
        send({"id": next(ids), **msg})
        return recv()

    return call


def relay_on(call, ieee):
    """Reads a plug's relay over the air: the OnOff cluster's OnOff
    attribute on its first endpoint. None when the plug did not answer."""
    r = call({
        "type": "zha/devices/clusters/attributes/value",
        "ieee": ieee,
        "endpoint_id": 1,
        "cluster_id": 6,
        "cluster_type": "in",
        "attribute": 0,
    })
    if not r.get("success"):
        return None
    # ZHA renders the attribute as its enum name, "Bool.true".
    return str(r["result"]).lower().endswith("true")


def nwk(v):
    """Device nwk arrives as an integer, neighbor and route ones as hex."""
    return int(v, 16) if isinstance(v, str) else v


def number(v):
    """Neighbor LQI and depth arrive as strings."""
    try:
        return int(v)
    except (TypeError, ValueError):
        return None


def escape(v):
    return v.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def main():
    url, token_file, prom = sys.argv[1:]
    if url == "-":
        call = None
        devices = json.load(open(token_file))
    else:
        call = connect(url, open(token_file).read().strip())
        r = call({"type": "zha/devices"})
        if not r.get("success"):
            sys.exit(f"zha/devices failed: {r.get('error')}")
        devices = r["result"]
    if not devices:
        sys.exit("zha/devices returned no devices")

    # The user-given name, else ZHA's model name. Names label every series,
    # so a name held by more than one device gets its ieee appended to keep
    # each series distinct.
    names = {d["ieee"]: d.get("user_given_name") or d["name"] for d in devices}
    taken = list(names.values())
    for ieee, name in names.items():
        if taken.count(name) > 1:
            names[ieee] = f"{name} ({ieee})"
    by_nwk = {nwk(d["nwk"]): names[d["ieee"]] for d in devices}

    def name(ieee):
        return names.get(ieee, ieee)

    def nwk_name(v):
        return by_nwk.get(nwk(v), v)

    # A device's parent is the router whose table lists it as a child; end
    # devices keep no table of their own. A router the coordinator lists
    # only as a sibling names its parent in its own table instead. After a
    # device moves, its old parent's child entry can linger until that
    # router's next scan, so tables disagree for a while; the first claim
    # in ZHA's order wins, and the Loki lines keep every table.
    parents = {}
    for d in devices:
        for n in d.get("neighbors") or []:
            if n["relationship"] == "Child":
                parents.setdefault(n["ieee"], names[d["ieee"]])
    for d in devices:
        for n in d.get("neighbors") or []:
            if n["relationship"] == "Parent":
                parents.setdefault(d["ieee"], name(n["ieee"]))

    def line(kind, obj):
        print(f"kind={kind} {json.dumps(obj, separators=(',', ':'))}")

    info, avail, links, relays = {}, {}, {}, {}
    for d in devices:
        dev = names[d["ieee"]]
        parent = parents.get(d["ieee"], "")
        avail[(dev, d["ieee"])] = int(d["available"])

        # The smart plugs are routers for the mesh and metered outlets,
        # so their relays stay on; the plug's own button is the only
        # thing left that can switch one off.
        if call and d["model"].startswith("lumi.plug"):
            on = relay_on(call, d["ieee"])
            if on is not None:
                relays[(dev, d["ieee"])] = int(on)
        line("zigbee-device", {
            "name": dev,
            "ieee": d["ieee"],
            "type": d["device_type"],
            "parent": parent,
            "available": d["available"],
            "last_seen": d["last_seen"],
            "lqi": d["lqi"],
            "rssi": d["rssi"],
        })
        info[(dev, d["ieee"], d["device_type"], parent)] = 1

        for n in d.get("neighbors") or []:
            lqi = number(n["lqi"])
            line("zigbee-link", {
                "device": dev,
                "neighbor": name(n["ieee"]),
                "relationship": n["relationship"],
                "lqi": lqi,
                "depth": number(n["depth"]),
            })
            if lqi is not None:
                links[(dev, name(n["ieee"]), n["relationship"])] = lqi

        for r in d.get("routes") or []:
            line("zigbee-route", {
                "device": dev,
                "destination": nwk_name(r["dest_nwk"]),
                "next_hop": nwk_name(r["next_hop"]),
                "status": r["route_status"],
            })

    def series(metric, keys, values):
        for labels, v in sorted(values.items()):
            pairs = ",".join(
                f'{k}="{escape(x)}"' for k, x in zip(keys, labels)
            )
            yield f"{metric}{{{pairs}}} {v}"

    out = [
        "# HELP homelab_zigbee_device_info A device on the Zigbee mesh, "
        "by type and parent router; always 1.",
        "# TYPE homelab_zigbee_device_info gauge",
        *series(
            "homelab_zigbee_device_info",
            ["device", "ieee", "type", "parent"],
            info,
        ),
        "# HELP homelab_zigbee_device_available Whether ZHA has heard "
        "from the device within its availability timeout.",
        "# TYPE homelab_zigbee_device_available gauge",
        *series("homelab_zigbee_device_available", ["device", "ieee"], avail),
        "# HELP homelab_zigbee_link_lqi Link quality of a neighbor in a "
        "Zigbee router's neighbor table, as that router reports it.",
        "# TYPE homelab_zigbee_link_lqi gauge",
        *series(
            "homelab_zigbee_link_lqi",
            ["device", "neighbor", "relationship"],
            links,
        ),
        "# HELP homelab_zigbee_plug_on Whether a smart plug's relay is "
        "on, read from the plug.",
        "# TYPE homelab_zigbee_plug_on gauge",
        *series("homelab_zigbee_plug_on", ["device", "ieee"], relays),
    ]

    # Renamed into place so a scrape never sees half a file, and a failed
    # run leaves the last good one: .prom.tmp is outside the glob.
    with open(prom + ".tmp", "w") as f:
        f.write("\n".join(out) + "\n")
    os.rename(prom + ".tmp", prom)


main()
