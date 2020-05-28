// Command vargen produces computed JSON data for use in vars.nix.
package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net"
	"os"

	"github.com/mdlayher/netx/eui64"
	"inet.af/netaddr"
)

//go:generate /usr/bin/env bash -c "go run main.go > ../vars.json"

func main() {
	// LLA is always the same.
	lla := prefix("fe80::/64")

	// The primary subnet: all servers and network infrastructure live here.
	var (
		// TODO: renumber to "0"?
		enp2s0 = subnet{
			Name: "enp2s0",
			IPv4: prefix("192.168.1.0/24"),
			IPv6: ipv6Prefixes{
				GUA: prefix("2600:6c4a:7880:3200::/64"),
				LLA: lla,
				ULA: prefix("fd9e:1a04:f01d::/64"),
			},
		}

		lan0   = newSubnet("lan0", 10)
		iot0   = newSubnet("iot0", 66)
		tengb0 = newSubnet("tengb0", 100)
	)

	// Set up the output structure and create host/infra records.
	out := output{
		Hosts: hosts{
			Servers: []host{
				newHost(
					"servnerr-3",
					enp2s0,
					ip("192.168.1.4"),
					mac("1c:1b:0d:ea:83:0f"),
				),
				newHost(
					"nerr-3",
					enp2s0,
					ip("192.168.1.9"),
					mac("04:d9:f5:7e:1c:47"),
				),
				newHost(
					"monitnerr-1",
					enp2s0,
					ip("192.168.1.11"),
					mac("dc:a6:32:1e:66:94"),
				),
			},
			Infra: []host{
				newHost(
					"switch-livingroom01",
					enp2s0,
					ip("192.168.1.2"),
					mac("f0:9f:c2:0b:28:ca"),
				),
				newHost(
					"switch-office01",
					enp2s0,
					ip("192.168.1.3"),
					mac("f0:9f:c2:ce:7e:e1"),
				),
				newHost(
					"switch-office02",
					tengb0,
					ip("192.168.100.2"),
					mac("c4:ad:34:ba:40:82"),
				),
				newHost(
					"ap-livingroom02",
					enp2s0,
					ip("192.168.1.5"),
					mac("74:83:c2:7a:c6:15"),
				),
				newHost(
					"keylight",
					iot0,
					ip("192.168.66.10"),
					mac("3c:6a:9d:12:c4:dc"),
				),
			},
		},
	}

	// Attach interface definitions from subnet definitions.
	out.addInterface("enp2s0", enp2s0)
	out.addInterface("lan0", lan0)
	out.addInterface("guest0", newSubnet("guest0", 9))
	out.addInterface("iot0", iot0)
	out.addInterface("lab0", newSubnet("lab0", 2))
	out.addInterface("tengb0", tengb0)
	out.addInterface("wg0", newSubnet("wg0", 20))

	// TODO: wan0 is a special case but should probably live in its own
	// section as it has different rules.
	out.Interfaces["wan0"] = iface{
		Name: "enp1s0",
		// TODO: compute WAN addresses automatically?
		IPv4: ip("24.176.57.23"),
	}

	// Marshal human-readable JSON for nicer git diffs.
	e := json.NewEncoder(os.Stdout)
	e.SetIndent("", "\t")
	if err := e.Encode(out); err != nil {
		log.Fatalf("failed to encode JSON: %v", err)
	}
}

type output struct {
	Hosts      hosts            `json:"hosts"`
	Interfaces map[string]iface `json:"interfaces"`
}

type hosts struct {
	Servers []host `json:"servers"`
	Infra   []host `json:"infra"`
}

type iface struct {
	Name           string        `json:"name"`
	InternalDomain bool          `json:"internal_domain"`
	IPv4           netaddr.IP    `json:"ipv4"`
	IPv6           ipv6Addresses `json:"ipv6"`
}

type ipv6Addresses struct {
	GUA netaddr.IP `json:"gua"`
	ULA netaddr.IP `json:"ula"`
	LLA netaddr.IP `json:"lla"`
}

func newSubnet(iface string, vlan int) subnet {
	var gua netaddr.IPPrefix
	if vlan < 99 {
		gua = prefix(fmt.Sprintf("2600:6c4a:7880:32%02d::/64", vlan))
	} else {
		// Too large for decimal due to /56, so use hex.
		gua = prefix(fmt.Sprintf("2600:6c4a:7880:32%02x::/64", vlan))
	}

	return subnet{
		Name: iface,
		IPv4: prefix(fmt.Sprintf("192.168.%d.0/24", vlan)),
		IPv6: ipv6Prefixes{
			GUA: gua,
			LLA: prefix("fe80::/64"),
			ULA: prefix(fmt.Sprintf("fd9e:1a04:f01d:%d::/64", vlan)),
		},
	}
}

func newInterface(s subnet) iface {
	// TODO: this is a hack, come up with another convention to denote the
	// primary VLAN.
	var internal bool
	if s.Name == "lan0" || s.Name == "enp2s0" {
		internal = true
	}

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
		Name:           s.Name,
		InternalDomain: internal,
		IPv4:           netaddr.IPFrom16(ip4),
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
	Name string           `json:"name"`
	IPv4 netaddr.IPPrefix `json:"ipv4"`
	IPv6 ipv6Prefixes     `json:"ipv6"`
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

func ip(s string) netaddr.IP {
	ip, err := netaddr.ParseIP(s)
	if err != nil {
		panicf("failed to parse IP: %v", err)
	}

	return ip
}

func prefix(s string) netaddr.IPPrefix {
	ip, err := netaddr.ParseIPPrefix(s)
	if err != nil {
		panicf("failed to parse IPPrefix: %v", err)
	}

	return ip
}

func panicf(format string, a ...interface{}) {
	panic(fmt.Sprintf(format, a...))
}