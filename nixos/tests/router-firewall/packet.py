"""Packets for the router firewall test that nc and ping cannot send.

Run inside a namespace by run.sh:

  packet.py echo-hbh SRC DST   ICMPv6 echo from SRC behind a hop-by-hop
                               header; exits 0 when the reply arrives.
  packet.py mld GROUP IFACE    MLDv2 report for GROUP to ff02::16, with the
                               router alert option MLD carries.
  packet.py dhcp-discover IFACE
                               DHCPv4 discover from 0.0.0.0 to the limited
                               broadcast address.
  packet.py join IFACE GROUP...
                               Joins each multicast group on IFACE, then
                               forks a child holding the memberships and
                               exits once they are in place.
"""

import os
import select
import signal
import socket
import struct
import sys
import time

IPV6_HOPOPTS = 54
IPV6_JOIN_GROUP = 20

# Hop-by-hop headers as the kernel takes them in ancillary data: next header
# and length bytes (filled in by the kernel), then options padding the
# header to eight bytes.
HBH_PADN = bytes([0, 0, 1, 4, 0, 0, 0, 0])
HBH_ROUTER_ALERT_MLD = bytes([0, 0, 5, 2, 0, 0, 1, 0])


def icmp6_socket():
    s = socket.socket(socket.AF_INET6, socket.SOCK_RAW, socket.IPPROTO_ICMPV6)
    s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_MULTICAST_HOPS, 1)
    return s


def echo_hbh(src, dst):
    s = icmp6_socket()
    s.bind((src, 0))
    ident = os.getpid() & 0xFFFF
    # Type, code and checksum, which the kernel computes, then identifier
    # and sequence.
    msg = struct.pack("!BBHHH", 128, 0, 0, ident, 1) + b"router-firewall"
    s.sendmsg([msg], [(socket.IPPROTO_IPV6, IPV6_HOPOPTS, HBH_PADN)], 0, (dst, 0))
    deadline = time.monotonic() + 1
    while (left := deadline - time.monotonic()) > 0:
        if not select.select([s], [], [], left)[0]:
            break
        data = s.recv(1500)
        if len(data) >= 6 and data[0] == 129 and struct.unpack("!H", data[4:6])[0] == ident:
            return 0
    return 1


def mld(group, iface):
    s = icmp6_socket()
    record = struct.pack("!BBH", 4, 0, 0) + socket.inet_pton(socket.AF_INET6, group)
    msg = struct.pack("!BBHHH", 143, 0, 0, 0, 1) + record
    dst = ("ff02::16", 0, 0, socket.if_nametoindex(iface))
    s.sendmsg([msg], [(socket.IPPROTO_IPV6, IPV6_HOPOPTS, HBH_ROUTER_ALERT_MLD)], 0, dst)
    return 0


def checksum(data):
    total = sum(struct.unpack(f"!{len(data) // 2}H", data))
    total = (total >> 16) + (total & 0xFFFF)
    return ~(total + (total >> 16)) & 0xFFFF


def dhcp_discover(iface):
    s = socket.socket(socket.AF_INET, socket.SOCK_RAW, socket.IPPROTO_RAW)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_BINDTODEVICE, iface.encode())
    # op, htype, hlen, hops, xid, secs, flags (broadcast), four zero
    # addresses, chaddr, sname and file, then the magic cookie and the
    # message type option.
    bootp = (
        struct.pack("!BBBBIHH", 1, 1, 6, 0, 0x7E57, 0, 0x8000)
        + bytes(16)
        + bytes([2, 0, 0, 0, 0x7E, 0x57]) + bytes(10)
        + bytes(192)
        + bytes([99, 130, 83, 99, 53, 1, 1, 255])
    )
    udp = struct.pack("!HHHH", 68, 67, 8 + len(bootp), 0) + bootp
    src, dst = socket.inet_aton("0.0.0.0"), socket.inet_aton("255.255.255.255")
    header = struct.pack("!BBHHHBBH4s4s", 0x45, 0, 20 + len(udp), 0, 0, 1, 17, 0, src, dst)
    header = header[:10] + struct.pack("!H", checksum(header)) + header[12:]
    s.sendto(header + udp, ("255.255.255.255", 0))
    return 0


def join(iface, groups):
    index = socket.if_nametoindex(iface)
    held = []
    for group in groups:
        if ":" in group:
            s = socket.socket(socket.AF_INET6, socket.SOCK_DGRAM)
            mreq = socket.inet_pton(socket.AF_INET6, group) + struct.pack("@I", index)
            s.setsockopt(socket.IPPROTO_IPV6, IPV6_JOIN_GROUP, mreq)
        else:
            s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            mreqn = socket.inet_aton(group) + bytes(4) + struct.pack("@i", index)
            s.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, mreqn)
        held.append(s)
    if os.fork() == 0:
        # Off the build log, so the builder's exit is not held open.
        null = os.open(os.devnull, os.O_RDWR)
        for fd in range(3):
            os.dup2(null, fd)
        signal.pause()
    return 0


def main(argv):
    match argv:
        case ["echo-hbh", src, dst]:
            return echo_hbh(src, dst)
        case ["mld", group, iface]:
            return mld(group, iface)
        case ["dhcp-discover", iface]:
            return dhcp_discover(iface)
        case ["join", iface, *groups] if groups:
            return join(iface, groups)
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
