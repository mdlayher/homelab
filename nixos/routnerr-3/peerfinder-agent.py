#!/usr/bin/env python3
#
# Measurement agent for the dn42 Peer Finder.
# https://peerfinder.dn42.dev
#
# The agent listens on a TCP port for measurement requests sent by the peerfinder.
#
# Setup (standard library only):
#
#   export SECRET_KEY="<secret returned during registration>"
#   export SECRET_KEY_FILE="/path/to/secret.key"  # Alternative to SECRET_KEY
#   export LISTEN_PORT="9000"      # Optional (default: 9000)
#   export LOG_LEVEL="INFO"        # Optional (default: INFO)
#
# This script requires permission to send ICMP echo requests via ping.

import hashlib
import hmac
import json
import os
import socket
import struct
import subprocess
import sys
import time
import logging
import threading
import re
from concurrent.futures import ThreadPoolExecutor
from typing import TypedDict, Optional

# --- Configuration ---
LISTEN_HOST, LISTEN_PORT = "::", int(os.environ.get("LISTEN_PORT", "9000"))
LOG_LEVEL = os.getenv("LOG_LEVEL", "INFO").upper()

# --- Constants ---
AGENT_VERSION = "1.2.0"
NB_PINGS = 4
MAX_TIMESTAMP_SKEW = 30
CONN_TIMEOUT = 15
AUTH_DEADLINE = 3
MAX_WORKERS = 8

# Frame constants
SIG_SIZE, TS_SIZE, NONCE_SIZE = 32, 8, 32
HEADER = struct.Struct(f">{SIG_SIZE}s {TS_SIZE}s {NONCE_SIZE}s H")
MAX_BODY_SIZE = 2000

# Logging setup
logging.basicConfig(
    level=getattr(logging, LOG_LEVEL, logging.INFO),
    format='%(asctime)s [%(levelname)s] %(message)s',
    datefmt='%Y-%m-%d %H:%M:%S'
)
logger = logging.getLogger("peerfinder")

# --- Obtain key ---
key_file = os.environ.get("SECRET_KEY_FILE")
if key_file:
    with open(key_file) as f:
        raw_key = f.read().strip()
else:
    raw_key = os.environ.get("SECRET_KEY")

if not raw_key:
    logger.error("SECRET_KEY or SECRET_KEY_FILE not set")
    sys.exit(1)

try:
    HMAC_KEY = bytes.fromhex(raw_key)
    if not len(HMAC_KEY) == 32: raise ValueError()
except ValueError:
    logger.error("The secret key must be a hex string and of correct length")
    sys.exit(1)


class NonceCache:
    """Tracks nonces seen within MAX_TIMESTAMP_SKEW of the request's own timestamp"""

    def __init__(self, window):
        self.window = window
        self.lock = threading.Lock()
        self.seen = {}

    def check_and_add(self, nonce, req_ts, now):
        with self.lock:
            # Cleanup expired nonces
            self.seen = {n: exp for n, exp in self.seen.items() if exp >= now}
            if nonce in self.seen:
                return False
            self.seen[nonce] = req_ts + self.window
            return True


nonce_cache = NonceCache(MAX_TIMESTAMP_SKEW)


def sign(ts_buf: bytes, nonce_buf: bytes, body: bytes, response: bool = False, legacy: bool = False) -> bytes:
    mac = hmac.new(HMAC_KEY, digestmod=hashlib.sha256)
    if response:
        mac.update(b"\x01")
    elif not legacy:
        mac.update(b"\x00")
    for part in (ts_buf, nonce_buf, body):
        mac.update(part)
    return mac.digest()


def recv_exact(sock, n: int, deadline: float):
    chunks = []
    remaining = n
    while remaining > 0:
        timeout = deadline - time.monotonic()
        if timeout <= 0:
            raise socket.timeout("read deadline exceeded")
        sock.settimeout(timeout)
        chunk = sock.recv(remaining)
        if not chunk: raise EOFError("Closed")
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def is_valid_ip(address: str) -> bool:
    # Try IPv4
    try:
        socket.inet_pton(socket.AF_INET, address)
        return True
    except socket.error:
        pass
    # Try IPv6
    try:
        socket.inet_pton(socket.AF_INET6, address)
        return True
    except socket.error:
        pass
    return False


class PingResult(TypedDict):
    reachable: bool
    sent: int
    recv: int
    latency: Optional[float]
    jitter: Optional[float]
    min_rtt: Optional[float]
    max_rtt: Optional[float]
    version: Optional[str]


def get_default_ping_result() -> PingResult:
    return {"reachable": False, "sent": 0, "recv": 0,
            "latency": None, "jitter": None, "min_rtt": None, "max_rtt": None, "version": None}


def run_ping(ip: str) -> PingResult:
    if not is_valid_ip(ip):
        raise ValueError("Invalid IP address")

    # -n (numeric), -q (quiet), -c (count), -w (deadline in seconds)
    cmd = ["ping", "-n", "-q", "-c", str(NB_PINGS), "-w", "6", ip]

    try:
        env = {"LANG": "C", "LC_ALL": "C", "PATH": os.environ.get("PATH", "/usr/bin:/bin")}
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=10, env=env)
        return parse_ping_output(proc.stdout)
    except Exception as e:
        logger.error(f"Ping to {ip} failed: {e}")
        return get_default_ping_result()


def parse_ping_output(output) -> PingResult:
    res = get_default_ping_result()

    # Match packets transmitted/received
    pkt_match = re.search(r'(\d+) packets transmitted, (\d+) (?:packets )?received', output)
    if pkt_match:
        res["sent"] = int(pkt_match.group(1))
        res["recv"] = int(pkt_match.group(2))
        res["reachable"] = res["recv"] > 0

    # Match RTT stats: min/avg/max/mdev (or stddev)
    # Works for: rtt min/avg/max/mdev = 1.0/2.0/3.0/0.1 ms
    rtt_match = re.search(r'(\d+\.\d+)/(\d+\.\d+)/(\d+\.\d+)/(\d+\.\d+)', output)
    if rtt_match:
        res["min_rtt"] = float(rtt_match.group(1))
        res["latency"] = float(rtt_match.group(2))
        res["max_rtt"] = float(rtt_match.group(3))
        res["jitter"] = float(rtt_match.group(4))

    return res

def self_test() -> bool:
    logger.info("Running self-test")
    for ip in ("127.0.0.1", "::1"):
        res = run_ping(ip)
        if res["reachable"] and res["latency"] is not None and res["recv"] == NB_PINGS:
            logger.info("Self-test OK (%s): %s", ip, res)
            return True
        logger.warning("Self-test via %s failed: %s", ip, res)
    logger.error("Self-test FAILED (ping binary missing or lacking ICMP permission?)")
    return False

def handle_connection(conn, addr):
    # Communication
    # -------------
    # Requests are authenticated using an HMAC-SHA256 signature generated with the
    # shared secret from registration.
    #
    # Binary wire format (big-endian), used for both requests and responses:
    #
    #   32 bytes  HMAC-SHA256( marker || timestamp || nonce || body)
    #    8 bytes  Unix timestamp (uint64)
    #   32 bytes  Nonce
    #    2 bytes  Body length N (uint16)
    #    N bytes  JSON body
    #
    # Responses must echo the request timestamp and nonce exactly (request binding).
    # Both "version" and "ping" commands are used by the backend and must be supported.
    try:
        deadline = time.monotonic() + AUTH_DEADLINE

        header_bytes = recv_exact(conn, HEADER.size, deadline)
        sig, ts_buf, nonce_buf, body_len = HEADER.unpack(header_bytes)

        if body_len > MAX_BODY_SIZE: return

        body = recv_exact(conn, body_len, deadline)

        expected_sig = sign(ts_buf, nonce_buf, body)
        if not hmac.compare_digest(expected_sig, sig):
            # Transition period
            if not hmac.compare_digest(sign(ts_buf, nonce_buf, body, legacy=True), sig):
                return
            else:
                logger.debug("accepted legacy mac")

        req_ts = int.from_bytes(ts_buf, "big")
        if abs(time.time() - req_ts) > MAX_TIMESTAMP_SKEW:
            logger.warning("rejected stale request from %s" % (addr,))
            return

        if not nonce_cache.check_and_add(nonce_buf, req_ts, time.time()):
            logger.warning("rejected replayed nonce from %s" % (addr,))
            return

        conn.settimeout(CONN_TIMEOUT)

        req = json.loads(body.decode(encoding="utf-8", errors="strict"))
        command = req.get("command", "")

        if command == "version":
            logger.info("version check")
            result = {"version": AGENT_VERSION}
        elif command == "ping":
            ip = req.get("ip")
            if not ip: return
            logger.info(f"ping request: {ip}")
            result = run_ping(ip)
            result["version"] = AGENT_VERSION
        else:
            logger.warning("unknown command %r from %s" % (command, addr))
            result = {"error": "unknown command"}

        resp_payload = json.dumps(result).encode()

        # Echo back the exact request timestamp and nonce
        resp_sig = sign(ts_buf, nonce_buf, resp_payload, True)
        header = HEADER.pack(resp_sig, ts_buf, nonce_buf, len(resp_payload))
        conn.sendall(header + resp_payload)

    except (socket.timeout, EOFError, struct.error):
        pass
    except Exception as e:
        logger.error("handler error: %s" % e)
    finally:
        try:
            conn.close()
        except Exception:
            pass


slots = threading.BoundedSemaphore(MAX_WORKERS)


def serve(conn, addr):
    try:
        handle_connection(conn, addr)
    finally:
        slots.release()


def main():
    if not self_test():
        sys.exit(1)
    # Use dual-stack socket if possible
    srv = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        srv.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
    except (AttributeError, socket.error):
        pass

    srv.bind((LISTEN_HOST, LISTEN_PORT))
    srv.listen(6)
    logger.info(f"DN42 Peer Finder Agent v{AGENT_VERSION} listening on port {LISTEN_PORT}")

    with srv, ThreadPoolExecutor(max_workers=MAX_WORKERS) as executor:
        try:
            while True:
                slots.acquire()
                try:
                    conn, addr = srv.accept()
                except Exception:
                    slots.release()
                    time.sleep(1)
                    continue
                try:
                    executor.submit(serve, conn, addr)
                except Exception:
                    slots.release()
                    try:
                        conn.close()
                    except Exception:
                        pass
                    continue
        except KeyboardInterrupt:
            logger.info("Shutting down...")


if __name__ == "__main__":
    main()
