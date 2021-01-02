// Command vargen produces computed JSON data for use in vars.nix.
package main

import (
	"encoding/json"
	"fmt"
	"io/ioutil"
	"log"
	"net"
	"net/http"
	"os"
	"strings"

	"github.com/mdlayher/netx/eui64"
	"inet.af/netaddr"
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
	// Fetch IPv4 address and IPv6 prefix for use elsewhere.
	var (
		wan4 = wanIPv4()
		gua6 = wanIPv6Prefix()
	)

	const trusted = true

	// The primary subnet: all servers and network infrastructure live here.
	var (
		// Trusted subnets which will have internal DNS and other services
		// deployed on them.
		enp2s0 = newSubnet("enp2s0", 0, gua6, trusted)
		lan0   = newSubnet("lan0", 10, gua6, trusted)
		wg0    = newSubnet("wg0", 20, gua6, trusted)

		// When multiple subnets are available, prefer the 10GbE subnet.
		tengb0 = func() subnet {
			s := newSubnet("tengb0", 110, gua6, trusted)
			s.Preference = high
			return s
		}()

		// Untrusted subnets which do not necessarily, have internal DNS records
		// and other services deployed on them. The lab subnet is a bit of a
		// special case but it's probably best to treat it as hostile.
		lab0   = newSubnet("lab0", 2, gua6, !trusted)
		guest0 = newSubnet("guest0", 9, gua6, !trusted)
		iot0   = newSubnet("iot0", 66, gua6, !trusted)

		server = newHost(
			"servnerr-3",
			tengb0,
			netaddr.MustParseIP("192.168.110.5"),
			mac("90:e2:ba:5b:99:80"),
		)

		desktop = newHost(
			"nerr-3",
			tengb0,
			netaddr.MustParseIP("192.168.110.6"),
			mac("90:e2:ba:23:1a:3a"),
		)
	)

	wg := wireguard{
		Name:   "wg0",
		Subnet: wg0,
	}
	wg.addPeer("mdlayher-fastly", "VWRsPtbdGtcNyaQ+cFAZfZnYL05uj+XINQS6yQY5gQ8=")
	wg.addPeer("nerr-3", "UvwWyMQ1ckLEG82Qdooyr0UzJhqOlzzcx90DXuwMTDA=")

	// Set up the output structure and create host/infra records.
	out := output{
		// TODO: this is a hack, we should make a Service type or similar.
		ServerIPv4:  server.IPv4,
		ServerIPv6:  server.IPv6.GUA,
		DesktopIPv6: desktop.IPv6.GUA,
		Hosts: hosts{
			Servers: []host{
				server,
				desktop,
				newHost(
					"theatnerr-1",
					lan0,
					netaddr.MustParseIP("192.168.10.10"),
					mac("94:de:80:6c:0e:ef"),
				),
				newHost(
					"monitnerr-1",
					lan0,
					netaddr.MustParseIP("192.168.10.11"),
					mac("dc:a6:32:1e:66:94"),
				),
				newHost(
					"monitnerr-2",
					lan0,
					netaddr.MustParseIP("192.168.10.12"),
					mac("dc:a6:32:7e:b6:fe"),
				),
			},
			Infra: []host{
				newHost(
					"switch-livingroom01",
					enp2s0,
					netaddr.MustParseIP("192.168.1.2"),
					mac("f0:9f:c2:0b:28:ca"),
				),
				newHost(
					"switch-office01",
					enp2s0,
					netaddr.MustParseIP("192.168.1.3"),
					mac("f0:9f:c2:ce:7e:e1"),
				),
				newHost(
					"switch-office02",
					enp2s0,
					netaddr.MustParseIP("192.168.1.4"),
					mac("c4:ad:34:ba:40:82"),
				),
				newHost(
					"ap-livingroom02",
					enp2s0,
					netaddr.MustParseIP("192.168.1.5"),
					mac("74:83:c2:7a:c6:15"),
				),
				newHost(
					"keylight",
					iot0,
					netaddr.MustParseIP("192.168.66.10"),
					mac("3c:6a:9d:12:c4:dc"),
				),
			},
		},
		WireGuard: wg,
	}

	// Attach interface definitions from subnet definitions.
	out.addInterface("enp2s0", enp2s0)
	out.addInterface("lan0", lan0)
	out.addInterface("guest0", guest0)
	out.addInterface("iot0", iot0)
	out.addInterface("lab0", lab0)
	out.addInterface("tengb0", tengb0)
	out.addInterface("wg0", wg0)

	// TODO: WANs are special cases and should probably live in their own
	// section with different rules.
	out.Interfaces["wan0"] = iface{
		Name:       "enp1s0",
		Preference: medium,
		IPv4:       wan4,
	}
	out.Interfaces["wwan0"] = iface{
		Name:       "wwp0s19u1u3i12",
		Preference: medium,
	}

	// Marshal human-readable JSON for nicer git diffs.
	e := json.NewEncoder(os.Stdout)
	e.SetIndent("", "\t")
	if err := e.Encode(out); err != nil {
		log.Fatalf("failed to encode JSON: %v", err)
	}
}

func wanIPv4() netaddr.IP {
	res, err := http.Get("https://ipv4.icanhazip.com")
	if err != nil {
		log.Fatalf("failed to perform HTTP request: %v", err)
	}
	defer res.Body.Close()

	b, err := ioutil.ReadAll(res.Body)
	if err != nil {
		log.Fatalf("failed to read HTTP body: %v", err)
	}

	return netaddr.MustParseIP(strings.TrimSpace(string(b)))
}

func wanIPv6Prefix() netaddr.IPPrefix {
	res, err := http.Get("https://ipv6.icanhazip.com")
	if err != nil {
		log.Fatalf("failed to perform HTTP request: %v", err)
	}
	defer res.Body.Close()

	b, err := ioutil.ReadAll(res.Body)
	if err != nil {
		log.Fatalf("failed to read HTTP body: %v", err)
	}

	// We want to determine the WAN IPv6 prefix so we can use that elsewhere
	// when the ISP decides to change it after some period of time. The prefix
	// length is hardcoded so it can be used elsewhere.
	ip := netaddr.MustParseIP(strings.TrimSpace(string(b)))
	pfx, err := ip.Prefix(pdLen)
	if err != nil {
		log.Fatalf("failed to create prefix from IP: %v", err)
	}

	return pfx
}

type output struct {
	ServerIPv4  netaddr.IP       `json:"server_ipv4"`
	ServerIPv6  netaddr.IP       `json:"server_ipv6"`
	DesktopIPv6 netaddr.IP       `json:"desktop_ipv6"`
	Hosts       hosts            `json:"hosts"`
	Interfaces  map[string]iface `json:"interfaces"`
	WireGuard   wireguard        `json:"wireguard"`
}

type hosts struct {
	Servers []host `json:"servers"`
	Infra   []host `json:"infra"`
}

type iface struct {
	Name        string        `json:"name"`
	Preference  preference    `json:"preference"`
	InternalDNS bool          `json:"internal_dns"`
	IPv4        netaddr.IP    `json:"ipv4"`
	IPv6        ipv6Addresses `json:"ipv6"`
}

type ipv6Addresses struct {
	GUA netaddr.IP `json:"gua"`
	ULA netaddr.IP `json:"ula"`
	LLA netaddr.IP `json:"lla"`
}

func newSubnet(iface string, vlan int, gua netaddr.IPPrefix, trusted bool) subnet {
	// The GUA prefix passed is a larger prefix such as a /48 or /56 and must
	// be combined with the VLAN identifier to create a single /64 subnet for
	// use with machines.
	sub6 := gua.IP.As16()
	sub6[pdLen/8] = byte(vlan)
	gua.IP = netaddr.IPFrom16(sub6)
	gua.Bits = 64

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
		IPv4:       netaddr.MustParseIPPrefix(fmt.Sprintf("192.168.%d.0/24", v4Subnet)),
		IPv6: ipv6Prefixes{
			GUA: gua,
			LLA: netaddr.MustParseIPPrefix("fe80::/64"),
			ULA: netaddr.MustParseIPPrefix(fmt.Sprintf("fd9e:1a04:f01d:%d::/64", vlan)),
		},
	}
}

func newInterface(s subnet) iface {
	// Router always has a .1 or ::1 suffix.
	ip4 := s.IPv4.IP.As16()
	ip4[15] = 1

	gua := s.IPv6.GUA.IP.As16()
	gua[15] = 1

	ula := s.IPv6.ULA.IP.As16()
	ula[15] = 1

	lla := s.IPv6.LLA.IP.As16()
	lla[15] = 1

	return iface{
		Name:       s.Name,
		Preference: s.Preference,
		// Only trusted subnets get internal DNS records.
		InternalDNS: s.Trusted,
		IPv4:        netaddr.IPFrom16(ip4),
		IPv6: ipv6Addresses{
			GUA: netaddr.IPFrom16(gua),
			ULA: netaddr.IPFrom16(ula),
			LLA: netaddr.IPFrom16(lla),
		},
	}
}

func (o *output) addInterface(name string, s subnet) {
	if o.Interfaces == nil {
		o.Interfaces = make(map[string]iface)
	}

	o.Interfaces[name] = newInterface(s)
}

func newHost(hostname string, sub subnet, ip4 netaddr.IP, mac net.HardwareAddr) host {
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

type subnet struct {
	Name       string           `json:"name"`
	Preference preference       `json:"preference"`
	Trusted    bool             `json:"trusted"`
	IPv4       netaddr.IPPrefix `json:"ipv4"`
	IPv6       ipv6Prefixes     `json:"ipv6"`
}

type host struct {
	Name string        `json:"name"`
	IPv4 netaddr.IP    `json:"ipv4"`
	IPv6 ipv6Addresses `json:"ipv6"`
	MAC  string        `json:"mac"`
}

type ipv6Prefixes struct {
	GUA netaddr.IPPrefix `json:"gua"`
	ULA netaddr.IPPrefix `json:"ula"`
	LLA netaddr.IPPrefix `json:"lla"`
}

type wireguard struct {
	Name   string   `json:"name"`
	Subnet subnet   `json:"subnet"`
	Peers  []wgPeer `json:"peers"`

	idx int
}

func (wg *wireguard) addPeer(name, publicKey string) {
	defer func() { wg.idx++ }()

	const offset = 10

	var ips []string
	for _, ipp := range []netaddr.IPPrefix{
		wg.Subnet.IPv4,
		wg.Subnet.IPv6.GUA,
		wg.Subnet.IPv6.ULA,
		wg.Subnet.IPv6.LLA,
	} {
		// Router always has a .1 or ::1 suffix.
		arr := ipp.IP.As16()
		arr[15] = byte(offset + wg.idx)

		bits := 32
		if ipp.IP.Is6() {
			bits = 128
		}

		ips = append(ips, netaddr.IPPrefix{
			IP:   netaddr.IPFrom16(arr),
			Bits: uint8(bits),
		}.String())
	}

	wg.Peers = append(wg.Peers, wgPeer{
		Name:       name,
		PublicKey:  publicKey,
		AllowedIPs: ips,
	})
}

type wgPeer struct {
	Name       string   `json:"name"`
	PublicKey  string   `json:"public_key"`
	AllowedIPs []string `json:"allowed_ips"`
}

func mustStdIP(ip net.IP) netaddr.IP {
	out, ok := netaddr.FromStdIP(ip)
	if !ok {
		panicf("bad IP: %q", ip)
	}

	return out
}

func mustEUI64(prefix netaddr.IPPrefix, mac net.HardwareAddr) netaddr.IP {
	ip, err := eui64.ParseMAC(prefix.IPNet().IP, mac)
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
