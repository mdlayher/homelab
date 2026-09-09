# Homelab network hardware, 2026

A research study, September 2026: what could replace the Aruba Instant On
switches and access points with something that joins the rest of the homelab in
git, Prometheus and Loki. It is not a plan of record. Prices are US street or
list prices seen in August and September 2026 and will drift; second-hand prices
are flagged where they could not be verified. Sources are linked inline.

## 1. Recommendation

### What the replacement must serve

- Two switches, a core next to the router and the server and one in the
  living room, and two access points, basement and living room, all with
  management addresses on the management LAN.
- Five site VLANs (lan, guest, iot, dev, mgmt) plus the internal dn42 VLAN, all
  tagged on the trunk to the router and on the trunk to the server's 10GbE
  bridge port. The router trunks over a 1GbE port today and has an unused
  SFP+ port, so a 10G router trunk is available without new router hardware.
- PoE for the two access points. Every AP considered below runs on 802.3af or
  802.3at; only the largest Wi-Fi 7 units need 802.3bt.
- Metrics into the existing Prometheus and Alertmanager. Today the switches and
  APs are only pinged by the blackbox exporter, because Instant On exposes
  SNMP only when a switch is taken out of cloud management, and the APs never
  do ([Instant On feature request, open since 2021](https://community.instant-on.hpe.com/discussion/feature-request-snmp-settings-available-through-cloud-portal)).
- LLDP, so the topology is visible from the router and the server, which
  already run `lldpd`.
- IPv6-clean management: the inventory reserves EUI-64 addresses for the
  switches and APs on the management LAN, so the devices must take a SLAAC
  address there and answer on it.
- Room to grow: 10G between the server and the workstation for bulk storage,
  multi-gig for the next generation of APs, and 10G for the dn42 and
  BGP lab traffic between the server's containers and the router.
- It is a house. Fan noise and idle power draw are selection criteria, not
  footnotes.

### Shortlist

Three concrete configurations, in order of how much of the network ends up in
this repository. Costs are rough and exclude optics, cables and injectors
unless stated.

**A. NixOS switchdev core, OpenWrt edge, OpenWrt APs. Fully declarative.**

| Role | Hardware | Software | Rough cost |
|---|---|---|---|
| Core (10G/25G aggregation, VLAN trunks) | Used NVIDIA/Mellanox SN2010: 18x SFP28, 4x QSFP28, x86 control plane, half-width 1U | NixOS from this flake, `mlxsw` switchdev | $700 to $1,500 used, unverified; plus ~$60 for a quiet fan mod |
| Copper and PoE next to the core | Zyxel GS1900-24HP v2 (24x 1G PoE+, 2x SFP, fanless) or, smaller, a GS1900-8HP / Netgear GS310TP | OpenWrt 25.12, image built by Nix | $100 to $250 |
| Living room | Zyxel GS1900-8HP or Netgear GS310TP (8x 1G PoE, 2x SFP, fanless) | OpenWrt 25.12, image built by Nix | ~$100 |
| Access points | 2x Zyxel NWA50AX Pro (Wi-Fi 6, 2x2 + 3x3, 2.5GbE, 802.3at) | OpenWrt 25.12, image built by Nix | ~$110 each, unverified |
| Optics | SFP28 DACs to the server, the router's SFP+ port and the workstation; 1G/10G modules to the edge switches | | $100 to $200 |

Total: roughly $1,300 to $2,300, most of it the used core switch.

What "declarative" buys here: the core switch is a NixOS machine in the flake,
configured with a systemd-networkd bridge with VLAN filtering, `lldpd`,
`node_exporter`, alloy to Loki and sops, deployed with the same `deploy`
script and nightly auto-upgrade as the router and the server. The edge
switches and the APs are OpenWrt images whose UCI text configuration is baked
in at build time by [nix-openwrt-imagebuilder](https://github.com/astro/nix-openwrt-imagebuilder)
as flake outputs, flashed with `sysupgrade -n` so the device is exactly what
the image says, and monitored with `prometheus-node-exporter-lua`, `snmpd`
and `lldpd`. Nothing in this configuration has a controller, a cloud account
or a binary config blob.

Trade-offs: no Wi-Fi 6E or Wi-Fi 7, because no PoE ceiling AP with either is
in the OpenWrt hardware table yet; the SN2010 has no PoE and no copper, needs
a fan mod to be house-quiet, and draws about 35 W idle against roughly 10 W
for a fanless small-business switch; it is a second-hand datacenter part, and
the OpenWrt Realtek target has had PoE regressions on some models. It is also
two more boxes than today. Section 3 covers this path in detail.

**B. MikroTik, single vendor, declared through its API.**

| Role | Hardware | Rough cost |
|---|---|---|
| Core | CRS326-24G-2S+IN (24x 1G, 2x SFP+, fanless, RouterOS) with two 802.3at injectors for the APs; or CRS328-24P-4S+RM (24x PoE+, 4x SFP+, two fans) | $199 + injectors, or $360 to $489 |
| 10G | CRS309-1G-8S+IN (8x SFP+, fanless) if the core has too few SFP+ ports | $269 |
| Living room | CRS310-8G+2S+IN (8x 2.5G, 2x SFP+, one fan, silent at light load) | $219 |
| Access points | 2x cAP ax (Wi-Fi 6, 802.3af/at) | $129 each |

Total: roughly $800 to $1,300.

What "declarative" buys: RouterOS has every primitive needed (offloaded tagged
VLANs, SNMPv3, LLDP transmit and receive, SLAAC on a management VLAN
interface, a REST API), and the
[terraform-routeros](https://github.com/terraform-routeros/terraform-provider-routeros)
provider covers nearly the whole device from OpenTofu, in the same way the
tailnet and DNS are managed today. The honest caveats: the provider is a
one-maintainer project with a six-month release gap and open crash bugs as of
September 2026; `/export` is a readable backup but not an idempotent
reconciler; there is no 2.5G PoE switch and no 6 GHz ceiling AP in the
lineup; and MikroTik Wi-Fi roaming needs hand-tuning that UniFi does
automatically.

**C. UniFi, single vendor, projected from a self-hosted controller.**

| Role | Hardware | Rough cost |
|---|---|---|
| Core | USW-Pro-Max-16-PoE (12x 1G PoE+, 4x 2.5G PoE++, 2x SFP+, fanless, 180 W) | $399 |
| Living room | USW-Flex-2.5G-PoE (8x 2.5G PoE++, 10G combo uplink, fanless) | $199 + $79 adapter |
| Access points | 2x U7 Pro (Wi-Fi 7 tri-band, 802.3at) | $189 each |
| Controller | UniFi Network Application in a container on the server, plus UnPoller | $0 |

Total: roughly $1,050.

What "declarative" buys: networks and VLANs, port profiles, per-port overrides
on named devices, SSIDs, AP groups, zone firewall policies and the site
auto-upgrade flag as HCL, through the
[ubiquiti-community](https://github.com/ubiquiti-community/terraform-provider-unifi)
or [filipowm](https://registry.terraform.io/providers/filipowm/unifi/latest/docs)
forks of the archived provider. Device adoption, firmware versions and
controller settings stay in the UI; the controller is the source of truth
and git holds a projection of it. Management is IPv4-only, so the reserved
EUI-64 addresses go unused. In exchange it is the best Wi-Fi of the three,
the least effort, and the only one with Wi-Fi 7 in a PoE ceiling unit.

Two runners-up worth naming: Cisco Catalyst 1300 gives a fanless switch with a
plain-text running-config, SNMPv3, LLDP and IPv6 management with no license
and no cloud, but "declarative" means templating CLI text over SSH; TP-Link
Omada has the cheapest fanless 2.5G PoE hardware with SFP+ uplinks, but its
controller has an unreadable backup format and no usable Terraform provider.
Among second-hand enterprise switches, a Ruckus ICX7150-24P in fan-off mode
with an ICX7150-C12P in the living room is silent, cheap and has freely
downloadable firmware, and Juniper EX has the best commit-based text config
and a maintained Terraform provider; neither is declarative in the sense
this repo means, and neither does 2.5G quietly. Section 4.7 has the detail.

### The recommendation

Given the stated preference for NixOS and switchdev, configuration A is the
one to pursue, staged so that nothing is bet on an unproven box:

1. Buy the SN2010 first and prove it on the bench: firmware at 3.9.x or
   later, NixOS installed from USB over the serial console, the VLAN-aware
   bridge offloaded, fans held down by the `mlxsw` hwmon interface or a fan
   mod, node_exporter counters flowing. The Instant On gear stays in service
   until then.
2. Move the APs to OpenWrt built from this repo. The Zyxel units are cheap
   enough that a failed experiment costs little, and the pipeline carries
   over unchanged to a Wi-Fi 7 PoE AP when one lands in the OpenWrt table.
3. Replace the Instant On switches with the OpenWrt PoE edge switches last,
   once the core and APs are stable.

If Wi-Fi 7 or zero-maintenance Wi-Fi outranks git-managed APs, the mixed
answer is configuration A's core and edge with UniFi U7 APs on a self-hosted
controller, and that combination is discussed in section 5. If the used
market or the fan mod turns out to be unacceptable, configuration B is the
fallback that keeps OpenTofu as the source of truth.

## 2. Comparison

"Declarative" in the second column means, from best to worst: **NixOS**, the
device is a host in this flake; **image**, a text config baked into an image
built by Nix; **API**, a real Terraform provider or API that OpenTofu can
reconcile; **text**, a running-config that can be diffed in git and pushed
over SSH but not reconciled; **cloud**, an API whose source of truth is a
vendor's cloud; **none**, a web UI.

| Family | Declarative | SNMP | LLDP | PoE switch options | 10G / multi-gig | Noise | Idle power | Price class | Firmware from git | IPv6 mgmt |
|---|---|---|---|---|---|---|---|---|---|---|
| NixOS on Mellanox SN2010 | NixOS | node_exporter instead; net-snmp if wanted | lldpd | none | 18x SFP28, 4x QSFP28 | loud stock, quiet with fan mod | ~35 W | $700 to $1,500 used | yes, it is NixOS | yes |
| OpenWrt on Realtek switches | image | snmpd | lldpd | GS1900-8HP/24HP, GS310TP (1G) | XGS1210-12 / XGS1250-12 (2.5G and 10G, snapshot-quality) | fanless | ~5 to 15 W | $60 to $250 | yes, Nix-built sysupgrade | yes |
| MikroTik RouterOS | API (terraform-routeros, REST, ansible) | v1/v2c/v3, no LLDP-MIB | tx and rx | CRS328-24P (fans), CSS610-8P (SwOS only) | CRS309/310/312/326-4C+, CRS504 | mostly fanless | 7 to 25 W | $150 to $500 | script via REST or provider; device-mode button once | yes, SLAAC |
| Ubiquiti UniFi | API projection (community forks) | v2c/v3 read-only, not on Flex | LLDP-MED | Pro-Max-16/24, Flex-2.5G, Pro-XG | 2x SFP+ on Pro Max, 4x on Pro HD, 10GBase-T Pro XG | fanless below Pro Max 24 | 15 to 60 W max excl. PoE | $200 to $800 | site auto-upgrade toggle only | no |
| Cisco Catalyst 1200/1300 | text | v1/v2c/v3 | LLDP-MED | C1300-8P, 16P, 24P, 8MGP, 24MGP | 2 to 4x SFP+, 2.5G on MGP | fanless except 24MGP | 8 to 14 W | $335 to $1,365 | CLI/TFTP auto-update | yes |
| Cisco Meraki | cloud (official provider) | v2c/v3 read-only, enabled from cloud | yes | MS130-8P, MS130-12X | 2x SFP+ on 12X | 8P fanless | 8 to 19 W | $1,000 to $2,000 + $35 to $117 per device per year | API | since MS 15.1 |
| TP-Link Omada | API without provider; text in standalone mode | v1/v2c/v3 | LLDP-MED | SG2210XMP-M2, SG3218XP-M2 | 2x SFP+, 2.5G ports | fanless on the 8-port | ~15 W | $250 to $450 | controller API | standalone yes; controller mode unverified |
| Netgear M4250 / MS / Insight | text (M4250 only) | v3 on M4250 and Smart Pro; none on Plus | yes | GSM4210PX, MS510TXPP, MS108EUP | MS510TXPP multigig | GSM4210PX fan-off, others audible | 18 to 25 W | $700 to $2,700 | CLI/TFTP on M4250 | M4250 yes |
| FS.com FSOS / PicOS | text | v1/v2c/v3 | yes | S3400-24T4SP, S3410-24TS-P | S5860-20SQ | two fans | 28 W | $935 to $2,670 | CLI/TFTP | yes |
| SONiC whitebox | text (config_db.json) | built in | built in | AS4630-54PE | everything | datacenter fans | 100 W class | quote | ONIE | yes |
| DENT / Prestera | Linux switchdev, dormant project | net-snmp | lldpd | TN48M-P, AS4224-P | 4x SFP+ | 1U DC fans | unknown | eBay, unknown | possible in principle | yes |
| Juniper EX (used) | text with commit model; jeremmfr/junos provider | v3 | LLDP-MED | EX2300-C-12P fanless, EX2300/3400-24P with fans | 2 to 4x SFP+ | fanless compact only | 24 to 110 W max | $260 to $340 used | frozen: contract-gated | static only |
| Ruckus ICX (used) | text, no commit, deprecated ansible | v3 | LLDP-MED | ICX7150-C12P fanless, 7150-24P fan-off mode | 2 to 4x SFP+ | silent in fan-off mode | 20 to 32 W | $130 to $650 | free downloads, images to archive | unverified |
| Cisco Catalyst (used) | text with configure replace; iosxe provider on 9200 | v3 | LLDP-MED | 3560CX, 9200CX fanless | 2x SFP+ | fanless compacts | 24 to 34 W | $150 to $2,200 | contract-gated | SLAAC on SVI |
| Arista (used) | text with sessions, eAPI | v3 | LLDP-MED | 710P fanless, 720XP | 4x SFP28 on 720XP | 710P fanless | 46 to 141 W | $2,300+ for PoE models | A-Care-gated | SLAAC on SVI |

Access points:

| Family | Declarative | Wi-Fi | PoE in | Metrics | LLDP | Price |
|---|---|---|---|---|---|---|
| OpenWrt on Zyxel NWA50AX Pro | image | Wi-Fi 6, 2x2 + 3x3 | 802.3at | node_exporter-lua wifi collectors, snmpd | lldpd | ~$110 |
| NixOS hostapd on a mini PC or SBC | NixOS | Wi-Fi 6/6E with MT7915/MT7916 modules | via splitter | node_exporter wifi collector | lldpd | $150 to $300 assembled |
| UniFi U7 Lite / Pro / Pro Max | API projection | Wi-Fi 7 | 802.3af/at | UnPoller via controller, SNMP | yes | $99 to $279 |
| MikroTik cAP ax | API | Wi-Fi 6 | 802.3af/at | SNMP, REST | yes | $129 |
| Omada EAP772 / 773 | API without provider | Wi-Fi 7 | 802.3at | omada_exporter via controller, SNMP | yes | $172 to $192 |

## 3. The NixOS switchdev path in detail

### Which hardware has a mainline switchdev driver

The dream of a switch that is simply a NixOS host depends on the switch ASIC
having an upstream driver that offloads the kernel's bridge to hardware. The
list is short.

| ASIC / driver | Hardware | Upstream status | PoE | Verdict |
|---|---|---|---|---|
| NVIDIA Spectrum, `mlxsw` | SN2010 (18x SFP28, 4x QSFP28), SN2100 (16x QSFP28), SN2410 (48x SFP28, 8x QSFP28), SN2700 | The reference switchdev implementation; VLAN-aware bridge offload since 4.4, L3 IPv4/IPv6, VXLAN, tc-flower, ethtool counters, hwmon fan control; firmware must be current, from linux-firmware ([mlxsw wiki](https://github.com/Mellanox/mlxsw/wiki), [supported hardware](https://github.com/Mellanox/mlxsw/wiki/Supported-Hardware-and-Firmware)) | none | The only buyable option today |
| Marvell Prestera AC3X/AC5X, `prestera` | Delta TN48M / TN48M-P (48x 1G, 4x SFP+), Edgecore AS4224(-P), Delta DE-B54GE6X2 (16x 1G, 8x 2.5G, 6x 10G, PoE) | Mainline since 5.10 as a firmware-driven PCI driver covering L1, basic L2 and RX/TX ([LWN](https://lwn.net/Articles/830682/)); richer features only in Marvell's out-of-tree repo, still pushed in August 2026 ([switchdev-prestera](https://github.com/Marvell-switching/switchdev-prestera)); dentOS, the distribution built on it, last released in September 2023 ([releases](https://github.com/dentproject/dentOS/releases)) | TN48M-P and the Delta AC5X boards, controlled by a userspace daemon in dentOS | The hardware is exactly right, the software is dormant; no NixOS deployment documented |
| Microchip SparX-5 / LAN969x, `sparx5` | Reference boards only, e.g. EVB-LAN9696-24port (24x 1G, 4x SFP+, 802.3bt add-on) | Mainline switchdev, arm64 ([Microchip BSP](https://microchip-ung.github.io/bsp-doc/bsp/2024.03/supported-hw/lan969x.html)) | via add-on module | No retail product |
| Realtek RTL838x/839x/930x/931x | Zyxel GS1900, XGS1210-12, XGS1250-12; Netgear GS308T/GS310TP; many more | Not mainline beyond basic peripherals; the DSA switch driver lives in OpenWrt ([status](https://svanheule.net/switches/current_status)) | yes on many, via `realtek-poe` | OpenWrt, not NixOS |
| MediaTek MT7988, `mt7530` DSA | Banana Pi BPI-R4 (4x 1G, 2x SFP+), BPI-R4 Pro (adds 4x 2.5G through a MaxLinear switch chip, $165) | NixOS boots via `nixos-sbc` on a vendor kernel; SFP+ ports untested there ([felbinger.eu](https://felbinger.eu/blog/2025/05/31/nixos-router-banana-pi-r4.html), [nixos-sbc](https://github.com/nakato/nixos-sbc)) | optional PoE-in module | A router board, not a switch |

The server's kernel (6.18.48 at the time of writing) already
builds `mlxsw_spectrum`, `prestera`, the Realtek and Marvell DSA drivers as
modules with switchdev and bridge VLAN filtering enabled, so a Spectrum box
needs no kernel override, unlike the Debian deployments below which built
their own. The PoE PSE subsystem (`CONFIG_PSE_CONTROLLER`) is off, which does
not matter because no buyable mainline-driver switch has PoE.

### Prior art

Nobody has published a NixOS-on-Spectrum write-up, but three Debian and VyOS
deployments on the SN2010 establish that it is an ordinary x86 Linux install:

- Debian netinstall from USB, BIOS over the serial console, custom kernel with
  `mlxsw`; bridge VLAN filtering, spanning tree, BGP and OSPF, ECMP, port
  counters in the kernel, tc-flower hardware ACLs and sFlow all working;
  about 60 W at full load; an ~80,000-route ceiling; HPE-branded units
  complicate firmware upgrades ([benjojo](https://blog.benjojo.co.uk/post/sn2010-linux-hacking-switchdev)).
- Debian with systemd-networkd, node_exporter, hsflowd and a devlink exporter;
  the author ended up with 83 networkd files and recommends templating them,
  which is what Nix does ([rezero.org, May 2026](https://blog.rezero.org/byo-nos)).
- VyOS nightly on an SN2010 and an SN3800: firmware had to go from 3.7 to
  3.9.x first, ~35 W idle, all ports discovered by `mlxsw` with no special
  configuration, and "a bit too noisy for desktop use" until the fans were
  dealt with ([part 1](https://scottstuff.net/posts/2025/11/11/vyos-on-mellanox-sn2010-switch-part1/),
  [part 2](https://scottstuff.net/posts/2026/05/23/vyos-on-mellanox-switch-part2/)).

### The SN2010 as a house switch

- Ports: 18x SFP28 at 10/25GbE and 4x QSFP28 at 40/100GbE, splittable to
  4x 25GbE, per the product brief ([NVIDIA](https://network.nvidia.com/files/doc-2020/pb-sn2010.pdf)).
  Whether 1GbE copper SFP modules link in the SFP28 cages is not documented in
  the brief and should be tested before relying on it; the design below does
  not depend on it.
- Power: 57 W ATIS typical per the brief, ~35 W idle measured.
- Noise: four internal fans run at full speed by default. Two fixes are
  documented: hold them at about 35 % through the `mlxsw` hwmon interface, or
  replace the top cover with a 3D-printed one holding three 120 mm fans, which
  made the switch silent with the CPU under 25 °C and the ASIC under 40 °C
  ([part 2](https://scottstuff.net/posts/2026/05/23/vyos-on-mellanox-switch-part2/)).
  The fans are also reversible with three screws ([rezero](https://blog.rezero.org/byo-nos)).
- Form factor: half-width 1U, two AC power supplies, x86 four-core Atom C2000
  control plane, ONIE-bootable. The Atom C2000 family had the AVR54 clock
  erratum that killed early units; ask the seller for the board stepping or
  accept the risk.
- Price: used MSN2010-CB2F units are plentiful on eBay with listings dated
  June to August 2026, but price pages blocked scraping. The widely quoted
  $700 to $1,500 range is unverified.
- Firmware: `mlxsw` refuses old firmware; the linux-firmware package carries
  the required version and the driver flashes it, but units on very old
  firmware may need `mstflint` first.

### What it would look like in this repository

A new machine directory alongside the router and the server, added to the
inventory's `roles` map under a new `switch` role, built by `flake.nix`
and deployed with `nixos/deploy` like the others. Its networking module:

- One `Kind=bridge` netdev with `VLANFiltering=yes` and a
  `DefaultPVID` of the management VLAN, which `mlxsw` offloads; the driver
  supports only one VLAN-aware bridge per ASIC, which is all this network
  needs ([Switch Port Configuration](https://github.com/Mellanox/mlxsw/wiki/Switch-Port-Configuration)).
- One `.network` per front-panel port with a `[BridgeVLAN]` section:
  trunks to the router, the server and the edge switches carry every VLAN
  tagged; the workstation port is an access port on the home VLAN. Port
  names come from `udev` rules on the front-panel labels, as the VyOS write-up
  needed.
- A `Kind=vlan` netdev on the bridge for management, with
  `IPv6AcceptRA` and a static token as the server does, so the switch's
  address is predictable and the inventory's `token` mode applies (the
  switch entries change from `eui64` to `token`). No IPv4
  or IPv6 forwarding: the switch is L2 only and the router stays the router.
- `services.lldpd`, `services.prometheus.exporters.node` with the `ethtool`
  and `hwmon` collectors, alloy to Loki, sops for the host secrets, and the
  existing auto-upgrade. Auto-upgrade does not reboot, so kernel updates wait
  for a chosen moment; a switch reboot takes the whole LAN down for about a
  minute.
- A fan-curve unit writing the hwmon PWM targets, until the physical fan mod
  makes it unnecessary.

Monitoring becomes better than SNMP: per-port counters, link state, optics
temperatures via `ethtool`, fan speeds and ASIC temperature via `hwmon`,
and the existing machine alerts (down, disk, journal, upgrade failure) apply
unchanged because the switch is a machine. The blackbox ping job keeps
working for the edge devices.

### Copper, PoE and the edge

The SN2010 has no copper and no PoE, so the 1G devices on the management LAN
(the monitor, the PDU and UPS cards, the home automation host, the printer)
and the APs need a copper switch with PoE next to it, and the living room
needs a small one. The closest thing to NixOS there is OpenWrt on the
Realtek target, whose UCI configuration is text and whose image can be a Nix
derivation:

- 1G boards are mature: the Netgear GS310TP works on OpenWrt 25.12.5
  including SFP and PoE ([forum](https://forum.openwrt.org/t/upgrading-from-23-05-5-to-25-12-3-on-zyxel-gs1900-8/249824));
  the Zyxel GS1900-8HP and GS1900-24HP are long-supported, but the 24HP v1
  lost PoE control on 24.10 and again on 25.12.x while v2 is fine
  ([#18528](https://github.com/openwrt/openwrt/issues/18528), [#23557](https://github.com/openwrt/openwrt/issues/23557)).
  PoE is driven by the userspace `realtek-poe` daemon, which supports the
  Broadcom-dialect MCUs in those boards ([svanheule](https://svanheule.net/switches/software/poe_management)).
- Multi-gig Realtek boards are snapshot-quality: the Zyxel XGS1210-12
  (8x 1G, 2x 2.5G, 2x SFP+, fanless, ~$120) got working 2.5G ports in August
  2025 and has an open port-dies regression on rev B1
  ([#21205](https://github.com/openwrt/openwrt/issues/21205)); the XGS1250-12
  (8x 1G, 3x 10GBase-T, 1x SFP+) has a 1 W SFP+ cage and a bootloader with
  the serial console disabled, so a bad flash needs a chip programmer
  ([ToH](https://openwrt.org/toh/zyxel/xgs1250-12)). Neither has PoE.
- MikroTik CRS3xx under OpenWrt is not viable: the Prestera ASIC has no
  working OpenWrt switch driver as of August 2026
  ([forum](https://forum.openwrt.org/t/support-for-mikrotik-switching-hardware-1g-10-crs-series-with-marvell-arm-32bit-98dx3236-soc-prestera/48977)).

If OpenWrt PoE edge switches feel like too many moving parts, the closed
alternatives for the same job are a fanless MikroTik CRS326-24G-2S+IN with
two 802.3at injectors (RouterOS, SNMPv3, LLDP, SLAAC, $199), or a Cisco
C1300-8P-E-2G (~$495) in the living room.

Linux gained a PoE PSE subsystem in 6.10 with `ethtool --set-pse`, drivers
for the Microchip PD692x0, TI TPS23881 and, more recently, the Realtek and
Broadcom MCUs used in Realtek-based switches ([Bootlin](https://bootlin.com/blog/power-over-ethernet-poe-support-into-the-official-linux-kernel/),
[pse-pd tree](https://github.com/torvalds/linux/tree/master/drivers/net/pse-pd)).
It matters for the future: the day a mainline-driver switch with PoE is
buyable, the NixOS switch gains PoE with a kernel option and an `ethtool`
call. Today the only such boards are the dormant DENT ones.

### The DENT option, for the record

A Delta TN48M-P would be the ideal NixOS switch on paper: 48x 1G PoE+,
4x SFP+, arm64, mainline `prestera`, upstream device tree. Against it: the
mainline driver is L2-only and firmware-driven, PoE needs the dentOS
userspace daemon or new PSE work, the project's last release is from 2023,
the boxes have datacenter fans, and nobody has documented NixOS on one.
Worth revisiting if Marvell's out-of-tree work keeps landing upstream.

## 4. Details per family

### 4.1 Ubiquiti UniFi

Switches ([store](https://store.ui.com/us/en/category/all-switching), spec
sheets on techspecs.ui.com; "max W" is Ubiquiti's figure excluding PoE, which
is the closest thing it publishes to idle):

| Model | Ports | PoE budget | Uplinks | Cooling | Max W | Price |
|---|---|---|---|---|---|---|
| USW-Flex-2.5G-PoE | 8x 2.5G PoE++ | 196 W on the $79 adapter | 10GBase-T + SFP+ combo | fanless | 17 W | $199 |
| USW-Pro-Max-16-PoE | 12x 1G PoE+, 4x 2.5G PoE++ | 180 W | 2x SFP+ | fanless | 25 W | $399 |
| USW-Pro-Max-24-PoE | 16x 1G, 8x 2.5G | 400 W | 2x SFP+ | fans, audible ([owner thread](https://community.ui.com/questions/USW-Pro-Max-24-PoE-fan-rattle/ee2c83b0-9e70-4b1c-a91e-0e7efb3fe59d)) | 50 W | $799 |
| USW-Pro-XG-8-PoE | 8x 10GBase-T PoE++ | 155 W | 2x SFP+ | fan | 61 W | $499 |
| USW-Pro-HD-24 | 22x 2.5G, 2x 10GBase-T | none | 4x SFP+ | not stated | 60 W | $599 |
| USW-Aggregation | 8x SFP+ | none | | not stated | 36 W | $269 |
| USW-Enterprise-8-PoE | 8x 2.5G PoE+ | 120 W | 2x SFP+ | fanless | 30 W | $479, marked Vintage |

The Pro Max 16 is the natural fanless core but its two SFP+ ports are
consumed by the router and server trunks, leaving no 10G for the workstation
([StorageReview](https://www.storagereview.com/review/ubiquiti-pro-max-16-poe-review-16-ports-180w-poe-and-10gbe-uplinks));
the Pro HD 24 fixes that with four SFP+ and two 10GBase-T at the cost of PoE.
Flex and Ultra switches have no SNMP at all
([Ubiquiti](https://help.ui.com/hc/en-us/articles/33502980942615-SNMP-Monitoring-in-UniFi-Network)).

Access points: U7 Lite ($99, dual-band, 802.3af), U7 Pro ($189, tri-band,
802.3at), U7 Pro Max ($279), U7 Pro XG ($199, 10G uplink), U7 Pro XGS ($299,
needs 802.3bt); the U6 line is still sold ([store](https://store.ui.com/us/en/category/all-wifi),
[techspecs](https://techspecs.ui.com/unifi/wifi/u7-pro)). Only the XGS needs
more than PoE+.

Management. The Network Application is Java plus MongoDB. Ubiquiti steers
Linux self-hosting toward UniFi OS Server, a Podman-based package for Ubuntu
24.04 and Debian 13 where a UI account is optional ([help.ui.com](https://help.ui.com/hc/en-us/articles/34210126298775-Self-Hosting-UniFi));
the classic application still ships and Network 10.6 was released on
21 August 2026. nixpkgs packages `unifi` 10.6 and a `services.unifi`
module, but MongoDB is SSPL and treated as unfree, so every host compiles it
locally and a build breakage in late 2025 blocked the module for a while
([#461961](https://github.com/nixos/nixpkgs/issues/461961)). The practical
route is an OCI container on the server. `services.unpoller` exists in
nixpkgs and UnPoller is alive at v5.2.4 as of 5 September 2026
([releases](https://github.com/unpoller/unpoller/releases)); it polls the
controller, not the devices. Ubiquiti's IPv6 documentation covers client
addressing only, adoption uses the IPv4 inform URL, and no source describes
switches or APs being managed over IPv6
([IPv6 in UniFi](https://help.ui.com/hc/en-us/articles/36378535649687-Configuring-IPv6-in-UniFi)).

SNMP is a site-wide toggle, v1/v2c or v3, read-only, no traps, with a UI-MIB
Ubiquiti admits is incomplete; LibreNMS treats USW switches as EdgeSwitch
class, so IF-MIB and LLDP-MIB are the realistic coverage, with PoE coming from
the controller. LLDP-MED is a per-port setting on switches and APs transmit it.
Trunks are a native VLAN plus a tagged mode of Allow All, Block All or a
subtractive Custom list ([help.ui.com](https://help.ui.com/hc/en-us/articles/26136855808919-Switch-Port-VLAN-Assignment-Trunk-Access-Ports)).

Terraform. `paultyng/unifi` was archived on 30 April 2026 and there is no
official provider. `ubiquiti-community/unifi` (v0.55.0, July 2026) is the
drop-in successor with networks, port profiles, device port overrides, WLANs,
AP groups, zone-based firewall policies and the auto-upgrade setting;
`filipowm/unifi` (v1.1.0, July 2026) adds API-key auth and more settings but
breaks schema; `badgerops/unifi` is generated from the official Integration
API OpenAPI spec and explicitly excludes adoption and lifecycle
([badgerops](https://blog.badgerops.net/why-i-wrote-a-new-terraform-provider-for-unifi/)).
None manage adoption, firmware versions or controller settings. Backups are
AES-encrypted BSON dumps, not config files. Firmware from git means turning
site auto-upgrade off and posting upgrade URLs to the undocumented device
manager API. Standalone AP mode is app-only with no roaming
([help.ui.com](https://help.ui.com/hc/en-us/articles/12594679474071-Standalone-Access-Points-without-UniFi)),
so the controller is mandatory.

Verdict: partial declarativeness with community-maintained providers that
already turned over once in 2026, IPv4-only management, and the best Wi-Fi.

### 4.2 MikroTik RouterOS and SwOS

Switches (MikroTik list prices; power from ServeTheHome measurements where
available):

| Model | Ports | PoE-out | Uplinks | Fan | Idle / max W | Price |
|---|---|---|---|---|---|---|
| CRS310-8G+2S+IN | 8x 2.5G | none | 2x SFP+ | one, silent at light load, 43 to 46 dB loaded | 10.5 / 34 | $219 ([STH](https://www.servethehome.com/mikrotik-crs310-8g-2s-in-review-8-port-2-5gbe-and-2-port-10gbe-switch/3/)) |
| CRS326-24G-2S+IN | 24x 1G | none | 2x SFP+ | fanless | 9 / 24 | $199 ([STH](https://www.servethehome.com/mikrotik-crs326-24g-2sin-review-refreshing-a-classic-switch/3/)) |
| CRS328-24P-4S+RM | 24x 1G | 24x af/at, 450 W | 4x SFP+ | two | 19 to 25 / 44 | $489 list, ~$360 street ([STH](https://www.servethehome.com/mikrotik-crs328-24p-4s-rm-review-24-port-poe-and-4x-10gbe-switch/)) |
| CRS320-8P-8B-4S+RM | 16x 1G | 8x af/at + 8x bt | 4x SFP+ | three | 24 to 27 / n/p | $489 |
| CSS610-8P-2S+IN | 8x 1G | 8x af/at, 140 W | 2x SFP+ | fanless | n/p | $229, SwOS only |
| CRS309-1G-8S+IN | 1x 1G | none | 8x SFP+ | fanless | 7 to 8 / 23 | $269 |
| CRS304-4XG-IN | 4x 10GBase-T | none | | fanless | ~16 / 21 | $199 |
| CRS326-4C+20G+2Q+RM | 20x 2.5G, 4 combo | none | 2x QSFP+ | two, ~36 dBA | 31 / 70 | $999 |

There is no MikroTik 2.5G PoE switch, and the only fanless PoE switch is the
SwOS-only CSS610, which has no LLDP, SNMPv1/v2c only and no CLI
([SwOS manual](https://help.mikrotik.com/docs/spaces/SWOS/pages/76415036/CRS3xx+and+CSS3xx+series+Manual)).
Since RouterOS 7.17 switching a dual-boot unit to SwOS, or changing RouterBOOT
settings, needs one physical button press because of device-mode
([Device-mode](https://help.mikrotik.com/docs/spaces/ROS/pages/93749258/Device-mode)).

RouterOS 7.24.2 is current stable (3 September 2026). Bridge VLAN filtering,
STP and IGMP snooping stay hardware-offloaded on the Marvell CRS3xx
([chip features](https://help.mikrotik.com/docs/spaces/ROS/pages/30474317/Marvell+Prestera+switch+chip+features)).
SNMP v1/v2c/v3 with IF-MIB, BRIDGE-MIB, ENTITY-MIB and the MikroTik MIB, but
no LLDP-MIB; neighbours appear only in the MikroTik MIB neighbour table
([SNMP](https://help.mikrotik.com/docs/spaces/ROS/pages/8978519/SNMP)), and
`snmp_exporter`'s generator ships a `mikrotik` module for it. `ifSpeed`
reports 0 on 10G and faster ports since 7.3; use `ifHighSpeed`
([forum](https://forum.mikrotik.com/t/snmp-ifspeed-0-and-ifhighspeed-10000-non-rfc-compliant/270756)).
LLDP transmit and receive with management address and 802.1 VLAN TLVs
([Neighbor discovery](https://help.mikrotik.com/docs/spaces/ROS/pages/24805517/Neighbor+discovery)).
IPv6: with forwarding disabled the switch accepts router advertisements and
takes a SLAAC address, or a static EUI-64 address on the management VLAN
interface ([IPv6 settings](https://help.mikrotik.com/docs/spaces/ROS/pages/103841817/IPv6+Settings)).

Configuration as code. `/export` is diffable text but has no stable IDs and
is not idempotent to re-import; the documented path is reset then import
([Configuration management](https://help.mikrotik.com/docs/spaces/ROS/pages/328155/Configuration+Management)).
The REST API since 7.1 is a JSON wrapper over the console API
([REST API](https://help.mikrotik.com/docs/spaces/ROS/pages/47579162/REST+API)).
`terraform-routeros/routeros` has about 230 resources including bridge VLANs,
switch ports, SNMP, IPv6, neighbour discovery, wifi and CAPsMAN, and
RouterBOOT settings; it released near-weekly through December 2025, then
v1.99.1 on 8 March 2026 and nothing since, with open panics and a perpetual
diff on `bridge_vlan` tagged lists ([releases](https://github.com/terraform-routeros/terraform-provider-routeros/releases),
[issues](https://github.com/terraform-routeros/terraform-provider-routeros/issues)).
Ansible's `community.routeros` `api_modify` is idempotent per path and tracks
new RouterOS fields quickly ([docs](https://docs.ansible.com/projects/ansible/latest/collections/community/routeros/api_modify_module.html)).
Firmware: `/system/package/update` and `/tool/fetch` of a pinned `.npk`
are scriptable; RouterBOOT auto-upgrade is a provider resource but gated by
device-mode once.

Access points: cAP ax ($129, Wi-Fi 6 2x2, 802.3af/at, 1 GB RAM), wAP ax
($89), hAP ax2/ax3 (passive PoE only). Wi-Fi 7: hAP be lite ($79, no 6 GHz,
USB-C power), hAP be3 Media ($179, tri-band, 802.3af/at, "coming soon"); a
cAP be is unannounced as of July 2026 ([forum](https://forum.mikrotik.com/t/cap-be-eta/269476)).
The `wifi-qcom` driver does WPA3, 802.11r/k/v and per-SSID VLAN
([WiFi docs](https://help.mikrotik.com/docs/spaces/ROS/pages/224559120/WiFi)),
but roaming needs tuning: a nine-cAP-ax deployment in June 2026 still needed
ACL and threshold work for handsets ([forum](https://forum.mikrotik.com/t/roaming-with-cap-axs/271273)).

Verdict: every primitive is there and reachable from OpenTofu or Ansible,
which makes MikroTik the best closed-firmware fit for this repo; the provider's
maintenance state and the lack of 2.5G PoE and a 6 GHz ceiling AP are the
costs.

### 4.3 Cisco: Catalyst 1200/1300 and Meraki

Cisco Business 250/350 is end of sale (CBS350 since January 2025, software
maintenance ended January 2026) with Catalyst 1300 as the migration target
([Cisco](https://www.cisco.com/c/en/us/products/collateral/switches/business-350-series-managed-switches/business-350-series-managed-switches-eol.html)).

| Model | Ports | PoE | Fan | Idle / max W | Price |
|---|---|---|---|---|---|
| C1200-8P-E-2G | 8x 1G PoE+, 2x combo | 67 W | fanless | n/p / 88 | ~$335 |
| C1300-8P-E-2G | 8x 1G PoE+, 2x combo | 67 W | fanless | 7.8 / 88 | ~$495 |
| C1300-8MGP-2X | 4x 1G + 4x 2.5G PoE+, 2x SFP+ | 120 W | fanless | 10.4 / 145 | ~$795 |
| C1300-16P-4X | 16x 1G PoE+, 4x SFP+ | 120 W | fanless | 8.7 / 158 | ~$775 |
| C1300-24MGP-4X | 16x 1G + 8x 2.5G PoE+, 4x SFP+ | 375 W | one, under 39 dBA | 23.4 / 459 | ~$1,365 |

Figures from the [Catalyst 1300 datasheet](https://www.cisco.com/c/en/us/products/collateral/switches/catalyst-1300-series-switches/nb-06-cat1300-ser-data-sheet-cte-en.html);
prices from a reseller. There is no license to buy and no Smart Licensing
([at-a-glance](https://www.cisco.com/c/en/us/products/collateral/switches/catalyst-1200-series-switches/nb-06-cat1200-1300-ser-aag-cte-en.html)).
SNMP v1/v2c/v3, LLDP-MED, dual-stack management. The CLI is IOS-like but it is
the Linux-based small-business OS, not IOS-XE: `cisco.ios` Ansible modules do
not apply, `community.ciscosmb` offers only `command` and `facts`, and there
is no RESTCONF or NETCONF ([CLI guide](https://www.cisco.com/c/en/us/td/docs/switches/campus-lan-switches-access/Catalyst-1200-and-1300-Switches/cli/C1300-cli.html)).
Text config is first class: `show running-config`, `copy running-config
tftp://`, `copy tftp:// running-config`. Firmware via `boot host
auto-update` over TFTP or SCP. No cloud, no account.

Meraki: MS130-8P (~$993 plus a license), MS130-12X (8x 1G + 4x 2.5G, 2x SFP+,
~$1,987 plus $35 per year), CW9172I Wi-Fi 7 AP (~$785 plus $117 per year).
Devices stop forwarding client traffic 30 days after the license lapses and
resume when relicensed ([Meraki community](https://community.meraki.com/t5/Dashboard-Administration/What-will-happen-to-my-device-if-license-expired/td-p/4664)).
Local SNMP v2c/v3 exists but is enabled from the cloud; IPv6 switch management
since MS 15.1. Automation is the best of any vendor here: the official
`CiscoDevNet/meraki` provider has `meraki_switch_port` with VLAN and allowed
VLAN lists, networks, SSIDs and firmware windows ([registry](https://registry.terraform.io/providers/CiscoDevNet/meraki/latest/docs/resources/switch_port)).

Verdict: Catalyst 1300 is the most honest "text config in git" among closed
switches, fanless with SFP+ and 2.5G options, but you template CLI rather than
declare state. Meraki is truly declarative with the vendor's cloud as source
of truth, at two to four times the hardware price plus a perpetual
subscription.

### 4.4 TP-Link Omada

| Model | Ports | PoE | Fan | Idle W | Price |
|---|---|---|---|---|---|
| SG2210XMP-M2 | 8x 2.5G PoE+, 2x SFP+ | 160 W | fanless | ~15 measured | $250 ([review](https://dongknows.com/tp-link-omada-sg2210xmp-m2-poe-switch-review/)) |
| SG3218XP-M2 | 16x 2.5G (12 PoE+, 4 PoE++), 2x SFP+ | 240 W | two | 13.1 standby | |
| SG3428X | 24x 1G, 4x SFP+ | none | fanless | n/p / 23.6 max | $259 |
| SG2428P | 24x 1G PoE+, 4x SFP | 250 W | two | 14.4 standby | ~$437 |
| EAP772 / EAP773 (Wi-Fi 7) | 2.5G / 10G uplink | PoE+ in | | | $172 / $192 |

Standalone mode has a real CLI over SSH, SNMP v1/v2c/v3, LLDP-MED and dual-stack
management with DHCPv6 ([datasheet](https://static.tp-link.com/upload/product-overview/2026/202604/20260428/SG3218XP-M2(UN)%202.0_datasheet.pdf)).
In controller mode SNMP is pushed from the controller (v6.0+) and no source
documents IPv6 management addresses for adopted devices. The controller's
VLAN model is networks plus port profiles, the default untagged LAN cannot be
removed from a profile so a fully tagged trunk is not expressible
([request](https://community.tp-link.com/en/business/forum/topic/585454)),
and backups are encrypted `.cfg` files ([FAQ](https://support.omadanetworks.com/us/document/13008/)).
The Open API is OAuth JSON over most controller services and can install
firmware ([KB](https://community.tp-link.com/en/business/kb/detail/412930));
the only Terraform provider manages a single `site` resource
([Tohaker/omada](https://github.com/Tohaker/terraform-provider-omada)).
`omada_exporter` scrapes the controller for Prometheus
([repo](https://github.com/charlie-haley/omada_exporter)). TP-Link is under
US federal scrutiny with no ban on existing products in force as of mid-2026
([Wikipedia](https://en.wikipedia.org/wiki/TP-Link)).

Verdict: the cheapest fanless 2.5G PoE hardware with SFP+ uplinks, but
"declarative" means a JSON API without a provider, or CLI scraping in
standalone mode.

### 4.5 Netgear managed, including the M4250 AV line

| Model | Ports | PoE | Fan / noise | Idle W | Price |
|---|---|---|---|---|---|
| GSM4210PX (M4250-8G2XF-PoE+) | 8x 1G PoE+, 2x SFP+ | 220 W | fan-off mode up to 180 W PoE at 25 °C; 19.3 dBA quiet | 18.1 | ~$1,000 |
| GSM4212PX | 10x 1G, 2x SFP+ | 240 W | fan-off only under 90 W PoE and 35 °C | 25 | |
| MS510TXPP | 4x 1G, 2x 2.5G, 2x 5G PoE+, 10GBase-T, SFP+ | 180 W | one fan, 28.8 dBA | 19.4 | ~$702 |
| MS108EUP (Plus) | 8x 2.5G, PoE+ and PoE++ | 230 W | fanless | | ~$686 |
| GS728TPP | 24x 1G PoE+, 4x SFP | 380 W | two fans, 33.4 dBA | 22.5 | ~$938 |

From the [M4250 datasheet](https://www.downloads.netgear.com/files/GDC/M4250/M4250_Datasheet.pdf)
and reseller pages. Only the M4250 has a real CLI: Cisco-style
`show running-config`, TFTP scripts and `script apply`, SNMPv3, LLDP-MED
and IPv6 management ([CLI manual](https://www.downloads.netgear.com/files/GDC/M4250/M4250_CLI_Manual_EN.pdf)).
Smart Managed Pro units have SNMPv3 from a web UI; Plus units have no SNMP;
Insight is a per-device subscription whose SNMP is read-only v1/v2c and whose
REST API is a partner API. No Terraform or Ansible support exists for any
Netgear switch. Idle power is about double Cisco and TP-Link.

Verdict: the weakest declarative story and the most expensive per port; the
GSM4210PX is the only quiet one and it is $1,000 for eight 1G ports.

### 4.6 Whitebox: FS.com, SONiC, DENT, OpenWrt on switches

FS.com. The datacenter N-series runs FSOS, not SONiC. The S5860-20SQ
(20x SFP+, 4x SFP28, 2x QSFP+, two hot-swap fans) is sold in FSOS and PicOS
variants at roughly $1,400 to $2,670; the S3400-24T4SP (24x 1G PoE+, 4x SFP+,
370 W, two fans, 28 W without PoE load) is about $935 and the S3410-24TS-P is
its successor. FSOS is an IOS-style CLI whose startup config is a plain
`config.txt` on flash, with SNMP v1/v2c/v3 and LLDP and no API
([HON wiki](https://wiki.hon.one/networking/fs-fsos-switches/)): text over
SSH or TFTP, not reconciled.

SONiC. Community SONiC is healthy, with 202411 through 202605 release
branches and campus features like PVST+ and 802.1X arriving in 202505
([SONiC Foundation](https://sonicfoundation.dev/sonic-202505-powering-ai-fabrics-and-enterprise-networks-with-precision-and-insight/)).
`config_db.json` is a declarative-ish text file loaded at boot, but
`config load` does not remove deleted keys, so git-driven pushes need
`config reload` or the generic config updater ([design](https://github.com/sonic-net/SONiC/blob/master/doc/config-generic-update-rollback/SONiC_Generic_Config_Update_and_Rollback_Design.md)).
Every supported platform is a 1U datacenter chassis with datacenter fans
([platform list](https://sonic-net.github.io/SONiC/Supported-Devices-and-Platforms.html));
the only PoE-class entry is the Edgecore AS4630-54PE. No small quiet SONiC
box exists.

DENT. Last release v3.2 in September 2023, last commit September 2025, with a
"DENT 4.0 this year" note still on the docs site ([releases](https://github.com/dentproject/dentOS/releases)).
Its lasting output is upstream: the Prestera driver and the PoE PSE subsystem.
Hardware: Delta TN48M / TN48M-P / TN4810M, Edgecore AS4224(-P), Delta AC5X
boards with 2.5G and PoE ([supported hardware](https://github.com/dentproject/dentOS/wiki/Supported-Hardware)).

OpenWrt on switches. The Realtek target covers about 79 devices since 21.02;
OpenWrt 25.12.5 is current ([techref](https://openwrt.org/docs/techref/targets/realtek)).
UCI text config, the ImageBuilder with a `files/` overlay, `owut` for
package-preserving upgrades, and the `lldpd`, `snmpd` and
`prometheus-node-exporter-lua` packages fit the git model;
`nix-openwrt-imagebuilder` turns an image into a derivation (x86_64-linux
builders only) and was pushed on 6 September 2026. See section 3 for the
board-by-board state.

### 4.7 Enterprise second-hand: Arista, Juniper EX, Brocade ICX, Cisco Catalyst

Second-hand enterprise gear is where SNMPv3, LLDP-MED and text configuration
are table stakes, and where fan noise and firmware access decide everything.
Refurbisher prices below are roughly 1.5 to 3 times eBay auction prices, so
treat them as an upper bound; eBay figures in parentheses come from listing
snippets and are unverified.

| Model | Access / PoE | Uplinks | Noise | Idle or typical W | Refurb (eBay) | Firmware access |
|---|---|---|---|---|---|---|
| Juniper EX2300-C-12P | 12x PoE+ / 124 W | 2x SFP+ | fanless | 24 max | $262 | contract-gated |
| Juniper EX2300-24P | 24x PoE+ / 370 W | 4x SFP+ | two fans, user complaints | 80 max | $289 | contract-gated |
| Juniper EX3400-24P | 24x PoE+ / 370 W | 4x SFP+, 2x QSFP+ | fan modules plus PSU fans | 110 max | $338 | contract-gated |
| Juniper EX4100-F-12P | 12x PoE+ / 180 W | 2x multi-gig BASE-T, 4x SFP+ | fanless | external brick | ~$2,375 new | contract-gated |
| Arista 7010T-48 | 48x 1G, no PoE | 4x SFP+ | two fans | 52 | $153 to $163 | A-Care-gated |
| Arista 710P-12 | 12x PoE / 104 to 234 W | 2x SFP+ | fanless | 46 max | rare | A-Care-gated |
| Arista 720XP-24ZY4 | 16x 2.5G + 8x 5G PoE | 4x SFP28 | three fans | 141 excl. PoE | $2,473 | A-Care-gated |
| Ruckus ICX7150-C12P | 12x PoE+ / 124 W | 2x SFP+ (honor license) | fanless | 20 | $318 (~$130) | free, "All Users" |
| Ruckus ICX7150-24P | 24x PoE+ / 370 W, 150 W with fan off | 4x SFP+ (honor license) | 41.4 dBA at minimum fan; fan-off mode | 32 | $647 | free |
| Ruckus ICX7150-48ZP | 16x 2.5G PoH + 32x 1G | 8x SFP+ | 52 dBA | 89 | $940 to $1,053 | free |
| Ruckus ICX6450-24P | 24x PoE+ | 4x SFP+ (honor license) | ~50 dB stock, quiet after a fan swap | ~25 | (~$50) | free |
| Cisco 3560CX-12PD-S | 12x PoE+ / 240 W | 2x SFP+, 2x 1G | fanless | 29.5 | $1,117 ($220) | contract-gated, IOS 15.2(7)E is the last |
| Cisco 3560CX-8PC-S | 8x PoE+ / 240 W | 2x 1G SFP, 2x 1G | fanless | 24.4 | $153 | contract-gated |
| Cisco C9200CX-8P-2X2G | 8x PoE+ / 240 W | 2x SFP+, 2x 1G | fanless | 34 | $2,222 | contract-gated |
| Cisco C9200L-24P-4X | 24x PoE+ / 370 W | 4x SFP+ | 42 dB typical | 43 min | $1,748 | contract-gated |

Juniper EX. The EX2300-C-12P is fanless and the non-compact EX2300s have two
rear fans with no published dBA and enough complaints that eBay sells quiet
replacement fans for them ([hardware guide](https://www.juniper.net/documentation/us/en/hardware/ex2300/ex2300.pdf),
[community](https://community.juniper.net/discussion/reduce-fan-noise-on-ex2300-switch));
the EX3400 and EX4300 are wiring-closet boxes whose PSU fans rule them out of a
living space. The EX4100-F-12P is the fanless multi-gig unit, effectively
new-channel only. Junos is the best text-config model of any vendor:
`show configuration | display set`, `load override` to replace the whole
candidate, `commit confirmed` with automatic rollback, `commit check`, fifty
rollbacks, and NETCONF through PyEZ ([load](https://www.juniper.net/documentation/us/en/software/junos/cli/topics/topic-map/junos-config-files-loading.html),
[commit](https://www.juniper.net/documentation/us/en/software/junos/cli/topics/ref/command/commit.html)).
The `jeremmfr/junos` Terraform provider is the most actively maintained
switch provider of the four, with v2.20.0 on 17 August 2026
([releases](https://github.com/jeremmfr/terraform-provider-junos/releases));
the `junipernetworks.junos` Ansible collection was archived in March 2026
into Juniper's own [ansible-junos-stdlib](https://github.com/Juniper/ansible-junos-stdlib).
Two hard limits: Junos will not SLAAC its own address, so the management
address is static ([ND docs](https://www.juniper.net/documentation/en_US/junos/topics/topic-map/ipv6-interfaces-neighbor-discovery.html)),
and Junos downloads need a support contract, with a gray-market policy that
makes licenses non-transferable and reinstatement a fee per year of care
([policy](https://support.juniper.net/support/pdf/guidelines/gray-market-product-reinstatement-policy.pdf)).
HPE closed the acquisition in July 2025 and juniper.net datasheet URLs now
redirect into HPE's portal. You run whatever Junos ships on the unit.

Arista. Arista does make PoE and multi-gig campus switches, the 720XP line
and the fanless 710P/710XP-12, so the objection is not absence of PoE but
price ($2,300 and up used for 720XP) and EOS downloads gated behind A-Care
([720XP datasheet](https://www.arista.com/assets/data/pdf/Datasheets/CCS-720XP-Datasheet.pdf),
[710P](https://www.arista.com/assets/data/pdf/Datasheets/CCS-710P-Datasheet.pdf),
[support](https://www.arista.com/en/support/customer-support)). The cheap
7010T/7050 units have no PoE. EOS has configure sessions with commit and a
commit timer, eAPI, `arista.eos` Ansible, and SLAAC on an SVI
([EOS IPv6](https://www.arista.com/en/um-eos/eos-ipv6)); the only Terraform
provider targets CloudVision.

Ruckus ICX. The only vendor whose firmware is legitimately downloadable
without a contract: FastIron releases are labelled "All Users" behind a free
login ([FastIron 10.0.10e](https://support.ruckuswireless.com/software/4233-ruckus-icx-fastiron-10-0-10e-ga-software-release-zip)),
10G ports and L3 are honor-licensed, and the fohdeesha guides ship an archive
([fohdeesha](https://fohdeesha.com/docs/icx7150.html)). The ICX7150-24P is the
one 24-port, four-SFP+ core that can be silent without modding: the datasheet's
fan-off mode caps PoE at 150 W, which is enough for two APs
([datasheet](https://amt.com/wp-content/uploads/2024/10/Ruckus-ICX-7150-Switch-Data-Sheet-1-1.pdf),
[community](https://community.ruckuswireless.com/t5/ICX-Switches/ICX-7150-24P-fanless-operation/m-p/44448));
the C12P is fanless at 20 W. Against it: no commit model, config is a text
running-config pushed by TFTP plus reload, the `community.network` ICX Ansible
modules are deprecated with no successor, there is no Terraform provider, the
7150 family went end of sale in January 2026, and RUCKUS changed owners twice
in 2026 (CommScope to Vistance in January, Vistance to Belden on 1 July)
([Vistance](https://www.vistancenetworks.com/press-releases/)). Archive the
images. Whether FastIron can SLAAC its own management address could not be
verified; assume static.

Cisco Catalyst. The 3560CX compact units are fanless at 24 to 30 W, and the
12PD-S has two SFP+ ports, but their IOS 15.2(7)E is the last release with
no NETCONF or RESTCONF ([datasheet](https://www.cisco.com/c/en/us/products/collateral/switches/catalyst-3560-cx-series-switches/datasheet-c78-733229.html)).
The fanless 9200CX and the 9200L are IOS-XE with NETCONF and RESTCONF, and
the `CiscoDevNet/iosxe` Terraform provider reached v1.0.0 on 19 July 2026
([releases](https://github.com/CiscoDevNet/terraform-provider-iosxe/releases)),
so a 9200 is closer to declarative than assumed; `configure replace` with a
timed confirm is a real full-replace model on both IOS and IOS-XE
([Cisco](https://www.cisco.com/c/en/us/td/docs/switches/lan/catalyst9200/software/release/17-3/configuration_guide/sys_mgmt/b_173_sys_mgmt_9200_cg/configuration_replace_and_configuration_rollback.html)).
Licensing does not bite: the base Network Essentials license is perpetual,
and an expired DNA add-on is deactivated and the switch keeps switching
([9200 datasheet](https://www.cisco.com/c/en/us/products/collateral/switches/catalyst-9200-series-switches/nb-06-cat9200-ser-data-sheet-cte-en.html)).
Images do: a service contract is required for downloads, with security fixes
available from TAC on request. The 9200CX is also still expensive used.

Verdict: for a house, the quiet second-hand switches are the fanless compacts
(ICX7150-C12P, EX2300-C-12P, 3560CX, 9200CX) and the ICX7150-24P in fan-off
mode. Junos gives the best git workflow and the only maintained Terraform
provider, at the price of frozen firmware and a static management address;
ICX gives free firmware and silence at the price of no reconciler and a
deprecated automation stack. A concrete pairing would be an ICX7150-24P core
(~$300 to $650) with an ICX7150-C12P or EX2300-C-12P (~$130 to $320) in the
living room, but none of it is declarative in the sense this repo means, and
none of it does 2.5G quietly.

### 4.8 Access points

UniFi, MikroTik and Omada APs are covered above. The git-native options:

OpenWrt hardware. OpenWrt 25.12.0 shipped in March 2026 on kernel 6.12 with
wireless from 6.18 and the Wi-Fi scripts rewritten in ucode; 25.12.2 fixed a
severe 2.4 GHz latency regression in mt76 ([notes](https://openwrt.org/releases/25.12/notes-25.12.2)).
MediaTek mt76 is the healthy driver; Qualcomm ath11k APs still show
"failed to transmit frame" disconnects with no fix
([forum](https://forum.openwrt.org/t/ath11k-clients-disconnection/228515)),
and Wi-Fi 7 on both vendors is described as basic and unstable in 2026
([forum](https://forum.openwrt.org/t/mediatek-filogic-8000-is-out-in-ces-2026/245134)).
No PoE ceiling AP with Wi-Fi 6E or 7 is in the hardware table; Zyxel's BE
line runs Zyxel's own OpenWrt-derived firmware but has no upstream support.
One open bug matters: on 25.12 with SAE plus 802.11r, clients on Filogic
boards stop roaming ([#22200](https://github.com/openwrt/openwrt/issues/22200)),
so start with WPA2/WPA3 transition or WPA3 without fast transition.

| Device | PoE in | Radios | OpenWrt | Price |
|---|---|---|---|---|
| Zyxel NWA50AX Pro / NWA90AX Pro | 802.3at, 2.5GbE | MT7981 + MT7976, 2x2 + 3x3 Wi-Fi 6 | filogic, 23.05 to 25.12.5; 7 W idle, 13 W loaded ([ToH](https://openwrt.org/toh/zyxel/nwa50ax_pro), [forum](https://forum.openwrt.org/t/zyxel-nwa50ax-pro-performance/187650)) | ~$100 to $130, unverified |
| Ubiquiti U6+ | 802.3af/at | same silicon | filogic; `dd` to eMMC, ~120 MiB usable ([ToH](https://openwrt.org/toh/ubiquiti/unifi_6_plus)) | $129 |
| Ubiquiti U6 Lite / LR | PoE | MT7621/MT7622 + MT7915; Lite is 802.11n only on 2.4 GHz | supported with stock downgrade first | $99 |
| TP-Link EAP615-Wall, EAP613, EAP610 v3 | 802.3af/at | MT7621 + MT7915 2x2 | mt7621, 16 MB flash on the wall unit | $60 to $80 |
| TP-Link EAP683 LR | 802.3at, 2.5GbE | MT7986 + 2x MT7976 | filogic, page under construction | |
| OpenWrt One | 802.3af/at on the 2.5G port | MT7981 + MT7976 | reference board, router form factor | $89 |
| Banana Pi BPI-R4 + BE14 | none | MT7988 + MT7995 tri-band Wi-Fi 7 | snapshots, MLO experimental, 12 V 5 A needed | ~$150 + NIC |

The pipeline from this repo, all components verified: a per-AP attribute set
(profile, hostname, channels) rendered into `files/etc/config/network`
(bridge-vlan with the trunk port tagged for lan, guest and iot), `wireless`
(three `wifi-iface` per radio bound to those interfaces, shared
`mobility_domain`, 802.11r/k/v, `sae-mixed`), `system` (remote syslog to
the server, NTP), `snmpd`, `lldpd` and the node exporter's `wifi`,
`wifi_stations` and `hostapd_ubus_stations` collectors; `usteer` for band
steering; a `lan6` interface with DHCPv6 in `try` mode so SLAAC gives the
management address ([bridged AP](https://openwrt.org/docs/guide-user/network/wifi/wifiextenders/bridgedap)).
`nix-openwrt-imagebuilder` builds the image as a package output; deploy is
`scp` plus `sysupgrade -n`, which discards on-device state; a timer on the
server rebuilds nightly from `main`, compares the image hash and pushes only
on change. The wrinkle is secrets: a Nix-built image puts the SAE passphrase
in the store, so either accept that on the builder or ship placeholders and
have a `uci-defaults` script read a secrets file copied separately at deploy.
[dewclaw](https://github.com/MakiseKurisu/dewclaw) is the config-only
alternative, rendering Nix `uci.settings` into a script that applies over SSH
with rollback, managing some but not all of a device.

NixOS as an AP. The 2023 hostapd module rewrite supports multiple radios and
BSSes, WPA3 SAE, Wi-Fi 6 and 7 options and password files, but deferred VLANs
and 802.11r/k/v to the raw `settings` escape hatch ([PR #222536](https://github.com/NixOS/nixpkgs/pull/222536));
hostapd itself does per-BSS bridges and dynamic VLANs, so it is doable by
hand. Hardware is the problem: Intel cards cannot run a 5 GHz AP, MT7921/22
crash in AP mode, so it means an AsiaRF MT7915/MT7916 module ($22 to $30) in
a mini PC or SBC fed by a PoE splitter, on a shelf rather than a ceiling,
with mt76 AP-mode and DFS behaviour falling on you. node_exporter's `wifi`
collector, built on `github.com/mdlayher/wifi`, gives per-station metrics.
A fine project box; not the two units the household depends on.

## 5. Mixed vendor against single vendor

The families divide by what holds the truth. Controller families (UniFi,
Omada, Meraki, Insight) put it in a database or a cloud and hand git a
projection; text-config families (Catalyst 1300, FSOS, M4250, Junos) let git
hold it but reconcile by hand; API families (MikroTik, Meraki) let OpenTofu
reconcile; and Linux families (NixOS switchdev, OpenWrt images) make the
device a build output. Mixing across the first two groups multiplies the
places state lives. Mixing within the last group does not: a NixOS core and
Nix-built OpenWrt edge and APs are one workflow with two build systems, and
the trunk between them is a plain 802.1Q link that neither side needs a
controller to negotiate.

The one mixed combination worth considering outside that group is a NixOS
core with UniFi APs: it trades git-managed Wi-Fi for Wi-Fi 7, automatic
roaming and a controller container on the server, and it isolates the
controller's blast radius to Wi-Fi. The APs would then trunk into the OpenWrt
PoE edge switch, which needs nothing UniFi-specific. UnPoller covers the
metrics. The costs are the same as configuration C's Wi-Fi half: IPv4-only
management of the APs, adoption by hand, firmware by toggle.

A single-vendor UniFi or MikroTik build wins on effort and support: one UI,
one firmware train, one provider. It loses the thing this repo is built
around. For a network whose router already runs bird and nftables from Nix,
the marginal effort of the NixOS switch is smaller than it looks, and the
marginal effort of a controller is larger than it looks, because it is a
second source of truth to keep in step with the inventory.

## 6. Monitoring integration notes

- The NixOS switch and the OpenWrt devices need no SNMP: node_exporter on the
  switch and `prometheus-node-exporter-lua` on the OpenWrt boxes are scraped
  like any machine, and the existing exporter discovery on the server picks
  the switch up automatically.
- For SNMP devices, the packaged `snmp_exporter` configuration already carries
  `if_mib` generically and a `mikrotik` module; Cisco and UniFi switches
  answer `if_mib` and, where supported, `lldp`. UniFi APs are better polled
  through UnPoller and Omada through `omada_exporter`, both against the
  controller.
- LLDP neighbours from the router and the server, already collected by
  `lldpd`, gain switch and AP peers on every option except SwOS.
- The blackbox ping job stays as the liveness signal for anything that cannot
  run an exporter.

## Sources

Every claim above links to its source inline. Reports were compiled from the
vendors' documentation and stores, ServeTheHome and Dong Knows Tech reviews,
the OpenWrt table of hardware and forum, the mlxsw and Prestera wikis,
project release pages on GitHub, and the blog posts by benjojo, scottstuff
and rezero on Linux-native Spectrum switches. Web search for this study ran
out before every second-hand price could be confirmed; those figures are
marked unverified.
