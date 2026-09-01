package main

import (
	"bytes"
	"encoding/hex"
	"fmt"
	"net/netip"
	"strings"

	"github.com/google/nftables"
)

// fetchStats gathers named counter objects and per-element set counters from
// every nftables table via netlink. It requires CAP_NET_ADMIN.
func fetchStats() (*Stats, error) {
	c, err := nftables.New()
	if err != nil {
		return nil, fmt.Errorf("failed to dial netlink: %v", err)
	}
	defer func() { _ = c.CloseLasting() }()

	tables, err := c.ListTables()
	if err != nil {
		return nil, fmt.Errorf("failed to list tables: %v", err)
	}

	var stats Stats
	for _, t := range tables {
		family := familyName(t.Family)

		objs, err := c.GetObjects(t)
		if err != nil {
			return nil, fmt.Errorf("failed to get objects for table %q: %v", t.Name, err)
		}

		for _, o := range objs {
			cnt, ok := o.(*nftables.CounterObj)
			if !ok {
				continue
			}

			stats.Counters = append(stats.Counters, Counter{
				Family:  family,
				Table:   t.Name,
				Name:    cnt.Name,
				Bytes:   cnt.Bytes,
				Packets: cnt.Packets,
			})
		}

		sets, err := c.GetSets(t)
		if err != nil {
			return nil, fmt.Errorf("failed to get sets for table %q: %v", t.Name, err)
		}

		for _, s := range sets {
			if s.Anonymous {
				continue
			}

			elems, err := c.GetSetElements(s)
			if err != nil {
				return nil, fmt.Errorf("failed to get elements for set %q: %v", s.Name, err)
			}

			for _, e := range elems {
				// Only elements carrying counters are interesting.
				if e.Counter == nil {
					continue
				}

				stats.SetCounters = append(stats.SetCounters, SetCounter{
					Family:  family,
					Table:   t.Name,
					Set:     s.Name,
					Element: elementString(s.KeyType, e.Key),
					Bytes:   uint64(e.Counter.Bytes),
					Packets: uint64(e.Counter.Packets),
				})
			}
		}
	}

	return &stats, nil
}

// elementString produces a human-readable form of a set element key in nft
// list syntax: concatenated keys are split into their component datatypes
// and joined with " . ", matching how nft prints them.
func elementString(kt nftables.SetDatatype, key []byte) string {
	types := nftables.ConcatSetTypeElements(kt)
	if len(types) < 2 {
		return datatypeString(kt, key)
	}

	// Each component of a concatenated key is padded to a 4 byte boundary.
	parts := make([]string, 0, len(types))
	for _, t := range types {
		size := (int(t.Bytes) + 3) &^ 3
		if t.Bytes == 0 || size > len(key) {
			// An unknown datatype makes the remaining layout unknowable.
			parts = append(parts, hex.EncodeToString(key))
			break
		}

		parts = append(parts, datatypeString(t, key[:t.Bytes]))
		key = key[size:]
	}

	return strings.Join(parts, " . ")
}

// datatypeString produces a human-readable form of a single set element key
// component: IP addresses and interface names for those datatypes, and
// hexadecimal otherwise.
func datatypeString(t nftables.SetDatatype, key []byte) string {
	switch t.Name {
	case nftables.TypeIPAddr.Name, nftables.TypeIP6Addr.Name:
		if addr, ok := netip.AddrFromSlice(key); ok {
			return addr.String()
		}
	case nftables.TypeIFName.Name:
		return string(bytes.TrimRight(key, "\x00"))
	}

	// Unknown datatypes, and common address sets are still readable when the
	// exact datatype is unknown but the key length matches an address.
	if addr, ok := netip.AddrFromSlice(key); ok {
		return addr.String()
	}

	return hex.EncodeToString(key)
}

// familyName produces the nft CLI name for an nftables address family.
func familyName(f nftables.TableFamily) string {
	switch f {
	case nftables.TableFamilyINet:
		return "inet"
	case nftables.TableFamilyIPv4:
		return "ip"
	case nftables.TableFamilyIPv6:
		return "ip6"
	case nftables.TableFamilyARP:
		return "arp"
	case nftables.TableFamilyBridge:
		return "bridge"
	case nftables.TableFamilyNetdev:
		return "netdev"
	default:
		return fmt.Sprintf("unknown(%d)", f)
	}
}
