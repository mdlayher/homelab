// Command vargen produces computed JSON data for use in vars.nix.
package main

import (
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/netip"
	"os"
	"strings"

	"github.com/mdlayher/netx/eui64"
)

//go:generate /usr/bin/env bash -c "go run main.go > ../vars.json"

const (
	// pdLen is the length of the IPv6 prefix delegated to my router by Charter.
	pdLen = 56
)

// A preference is the preference of a given network interface.
type preference int

const (
	_ preference = iota
	low
	medium
	high
)

func (p preference) MarshalText() ([]byte, error) {
	switch p {
	case low:
		return []byte("low"), nil
	case medium:
		return []byte("medium"), nil
	case high:
		return []byte("high"), nil
	}

	panic("unhandled preference")
}

func main() {
	// Fetch IPv6 prefix for use elsewhere.
	gua6 := wanIPv6Prefix()

	const trusted = true

	// The primary subnet: all servers and network infrastructure live here.
	var (
		// Trusted subnets which will have internal DNS and other services
		// deployed on them.
		mgmt0 = newSubnet("mgmt0", 0, gua6, trusted)
		lan0  = newSubnet("lan0", 10, gua6, trusted)
		wg0   = newSubnet("wg0", 20, gua6, trusted)

		// Untrusted subnets which do not necessarily, have internal DNS records
		// and other services deployed on them. The lab subnet is a bit of a
		// special case but it's probably best to treat it as hostile.
		lab0   = newSubnet("lab0", 2, gua6, !trusted)
		guest0 = newSubnet("guest0", 9, gua6, !trusted)
		iot0   = newSubnet("iot0", 66, gua6, !trusted)

		server = mgmt0.newHost(
			"servnerr-4",
			netip.MustParseAddr("192.168.1.10"),
			mac("04:d9:f5:7e:1c:47"),
		)

		desktop = mgmt0.newHost(
			"nerr-4",
			netip.MustParseAddr("192.168.1.7"),
			mac("74:56:3c:43:73:37"),
		)
	)

	// Set up the output structure and create host/infra records.
	out := output{
		// TODO: this is a hack, we should make a Service type or similar.
		ServerIPv4:  server.IPv4,
		ServerIPv6:  server.IPv6.GUA,
		DesktopIPv4: desktop.IPv4,
		DesktopIPv6: desktop.IPv6.GUA,
		Hosts: hosts{
			Servers: []host{
				server,
				desktop,
				mgmt0.newHost(
					"monitnerr-1",
					netip.MustParseAddr("192.168.1.8"),
					mac("dc:a6:32:1e:66:94"),
				),
				lan0.newHost(
					"matt-3",
					netip.MustParseAddr("192.168.10.12"),
					mac("c4:bd:e5:1b:8a:e6"),
				),
				lan0.newHost(
					"matt-4",
					netip.MustParseAddr("192.168.10.13"),
					mac("14:ac:60:46:8d:91"),
				),
				lan0.newHost(
					"theatnerr-2",
					netip.MustParseAddr("192.168.10.14"),
					mac("18:c0:4d:91:04:d8"),
				),
			},
			Infra: []host{
				mgmt0.newHost(
					"switch-core",
					netip.MustParseAddr("192.168.1.2"),
					mac("44:5b:ed:f7:ce:da"),
				),
				mgmt0.newHost(
					"switch-livingroom",
					netip.MustParseAddr("192.168.1.3"),
					mac("ec:50:aa:42:0e:83"),
				),
				mgmt0.newHost(
					"switch-office",
					netip.MustParseAddr("192.168.1.4"),
					mac("74:ac:b9:e2:4e:a5"),
				),
				mgmt0.newHost(
					"pdu01",
					netip.MustParseAddr("192.168.1.5"),
					mac("00:0c:15:41:33:5e"),
				),
				mgmt0.newHost(
					"ap-livingroom",
					netip.MustParseAddr("192.168.1.6"),
					mac("34:3a:20:c8:a9:de"),
				),
				// desktop: 192.168.1.7
				// monitor: 192.168.1.8
				mgmt0.newHost(
					"ap-basement",
					netip.MustParseAddr("192.168.1.9"),
					mac("d0:4d:c6:c1:72:96"),
				),
				// server:  192.168.1.10
				mgmt0.newHost(
					"ups01",
					netip.MustParseAddr("192.168.1.11"),
					mac("00:0c:15:05:1e:e6"),
				),
				mgmt0.newHost(
					"hass",
					netip.MustParseAddr("192.168.1.12"),
					mac("52:54:00:22:db:4d"),
				),
				iot0.newHost(
					"keylight",
					netip.MustParseAddr("192.168.66.10"),
					mac("3c:6a:9d:12:c4:dc"),
				),
				iot0.newHost(
					"living-room-hue-hub.iot",
					netip.MustParseAddr("192.168.66.14"),
					mac("ec:b5:fa:1d:4f:c2"),
				),
				iot0.newHost(
					"living-room-myq-hub.iot",
					netip.MustParseAddr("192.168.66.15"),
					mac("cc:6a:10:0a:61:7f"),
				),
				iot0.newHost(
					"office-printer.iot",
					netip.MustParseAddr("192.168.66.16"),
					mac("40:b8:9a:27:d4:fd"),
				),
			},
		},
	}

	// Attach interface definitions from subnet definitions.
	out.addInterface("mgmt0", mgmt0)
	out.addInterface("lan0", lan0)
	out.addInterface("guest0", guest0)
	out.addInterface("iot0", iot0)
	out.addInterface("lab0", lab0)
	out.addInterface("wg0", wg0)

	// Marshal human-readable JSON for nicer git diffs.
	e := json.NewEncoder(os.Stdout)
	e.SetIndent("", "\t")
	if err := e.Encode(out); err != nil {
		log.Fatalf("failed to encode JSON: %v", err)
	}
}

func wanIPv6Prefix() netip.Prefix {
	res, err := http.Get("https://ipv6.icanhazip.com")
	if err != nil {
		log.Fatalf("failed to perform HTTP request: %v", err)
	}
	defer res.Body.Close()

	b, err := io.ReadAll(res.Body)
	if err != nil {
		log.Fatalf("failed to read HTTP body: %v", err)
	}

	// We want to determine the WAN IPv6 prefix so we can use that elsewhere
	// when the ISP decides to change it after some period of time. The prefix
	// length is hardcoded so it can be used elsewhere.
	ip := netip.MustParseAddr(strings.TrimSpace(string(b)))
	pfx, err := ip.Prefix(pdLen)
	if err != nil {
		log.Fatalf("failed to create prefix from IP: %v", err)
	}

	return pfx
}

type output struct {
	ServerIPv4  netip.Addr       `json:"server_ipv4"`
	ServerIPv6  netip.Addr       `json:"server_ipv6"`
	DesktopIPv4 netip.Addr       `json:"desktop_ipv4"`
	DesktopIPv6 netip.Addr       `json:"desktop_ipv6"`
	Hosts       hosts            `json:"hosts"`
	Interfaces  map[string]iface `json:"interfaces"`
}

type hosts struct {
	Servers []host `json:"servers"`
	Infra   []host `json:"infra"`
}

type iface struct {
	Name        string        `json:"name"`
	Preference  preference    `json:"preference"`
	InternalDNS bool          `json:"internal_dns"`
	IPv4        netip.Addr    `json:"ipv4"`
	IPv6        ipv6Addresses `json:"ipv6"`
	Hosts       []host        `json:"hosts"`
}

type ipv6Addresses struct {
	GUA netip.Addr `json:"gua"`
	ULA netip.Addr `json:"ula"`
	LLA netip.Addr `json:"lla"`
}

func newSubnet(iface string, vlan int, gua netip.Prefix, trusted bool) subnet {
	// The GUA prefix passed is a larger prefix such as a /48 or /56 and must
	// be combined with the VLAN identifier to create a single /64 subnet for
	// use with machines.
	sub6 := gua.Addr().As16()
	sub6[pdLen/8] = byte(vlan)
	gua = netip.PrefixFrom(netip.AddrFrom16(sub6), 64)

	// A hack to continue using 192.168.1.0/24 for the management network.
	v4Subnet := vlan
	if vlan == 0 {
		v4Subnet = 1
	}

	return subnet{
		Name: iface,
		// All subnets have medium preference by default.
		Preference: medium,
		Trusted:    trusted,
		IPv4:       netip.MustParsePrefix(fmt.Sprintf("192.168.%d.0/24", v4Subnet)),
		IPv6: ipv6Prefixes{
			GUA: gua,
			LLA: netip.MustParsePrefix("fe80::/64"),
			ULA: netip.MustParsePrefix(fmt.Sprintf("fd9e:1a04:f01d:%d::/64", vlan)),
		},
		Hosts: []host{},
	}
}

func newInterface(s subnet) iface {
	// Router always has a .1 or ::1 suffix.
	ip4 := s.IPv4.Addr().As4()
	ip4[3] = 1

	gua := s.IPv6.GUA.Addr().As16()
	gua[15] = 1

	ula := s.IPv6.ULA.Addr().As16()
	ula[15] = 1

	lla := s.IPv6.LLA.Addr().As16()
	lla[15] = 1

	return iface{
		Name:       s.Name,
		Preference: s.Preference,
		// Only trusted subnets get internal DNS records.
		InternalDNS: s.Trusted,
		IPv4:        netip.AddrFrom4(ip4),
		IPv6: ipv6Addresses{
			GUA: netip.AddrFrom16(gua),
			ULA: netip.AddrFrom16(ula),
			LLA: netip.AddrFrom16(lla),
		},
		Hosts: s.Hosts,
	}
}

func (o *output) addInterface(name string, s subnet) {
	if o.Interfaces == nil {
		o.Interfaces = make(map[string]iface)
	}

	o.Interfaces[name] = newInterface(s)
}

func newHost(hostname string, sub subnet, ip4 netip.Addr, mac net.HardwareAddr) host {
	// ip must belong to the input subnet.
	if !sub.IPv4.Contains(ip4) {
		panicf("subnet %q does not contain %q", sub.IPv4, ip4)
	}

	return host{
		Name: hostname,
		IPv4: ip4,
		IPv6: ipv6Addresses{
			// For now we use EUI-64 to compute all IPv6 addresses.
			GUA: mustEUI64(sub.IPv6.GUA, mac),
			ULA: mustEUI64(sub.IPv6.ULA, mac),
			LLA: mustEUI64(sub.IPv6.LLA, mac),
		},
		MAC: mac.String(),
	}
}

func (s *subnet) newHost(hostname string, ip4 netip.Addr, mac net.HardwareAddr) host {
	h := newHost(hostname, *s, ip4, mac)
	s.Hosts = append(s.Hosts, h)

	return h
}

type subnet struct {
	Name       string       `json:"name"`
	Preference preference   `json:"preference"`
	Trusted    bool         `json:"trusted"`
	IPv4       netip.Prefix `json:"ipv4"`
	IPv6       ipv6Prefixes `json:"ipv6"`
	Hosts      []host       `json:"hosts"`
}

type host struct {
	Name string        `json:"name"`
	IPv4 netip.Addr    `json:"ipv4"`
	IPv6 ipv6Addresses `json:"ipv6"`
	MAC  string        `json:"mac"`
}

type ipv6Prefixes struct {
	GUA netip.Prefix `json:"gua"`
	ULA netip.Prefix `json:"ula"`
	LLA netip.Prefix `json:"lla"`
}

func mustStdIP(ip net.IP) netip.Addr {
	out, ok := netip.AddrFromSlice(ip)
	if !ok {
		panicf("bad IP: %q", ip)
	}

	return out
}

func mustEUI64(prefix netip.Prefix, mac net.HardwareAddr) netip.Addr {
	ip, err := eui64.ParseMAC(prefix.Addr().AsSlice(), mac)
	if err != nil {
		panicf("failed to make EUI64: %v", err)
	}

	return mustStdIP(ip)
}

func mac(s string) net.HardwareAddr {
	mac, err := net.ParseMAC(s)
	if err != nil {
		panicf("failed to parse MAC: %v", err)
	}

	return mac
}

func panicf(format string, a ...interface{}) {
	panic(fmt.Sprintf(format, a...))
}
