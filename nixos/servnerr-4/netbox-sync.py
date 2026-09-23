# Mirrors the inventory rendered by netbox.nix into NetBox, through the ORM
# under `netbox-manage shell`. Every object it writes carries the homelab
# tag, and a tagged object absent from the input is deleted, so NetBox holds
# exactly what the last deploy described.
import collections
import ipaddress
import json
import os

from circuits.models import Circuit, CircuitTermination, CircuitType, Provider
from dcim.models import (
    Device,
    DeviceRole,
    DeviceType,
    Interface,
    MACAddress,
    Manufacturer,
    Site,
)
from django.db import transaction
from extras.models import Tag
from ipam.models import ASN, RIR, VLAN, IPAddress, Prefix

with open(os.environ["NETBOX_SYNC_INPUT"]) as f:
    want = json.load(f)


def net(s):
    return ipaddress.ip_network(s, strict=False)


with transaction.atomic():
    tag, _ = Tag.objects.get_or_create(
        slug="homelab",
        defaults={
            "name": "homelab",
            "description": "Mirrored from the homelab repository; edits are overwritten",
        },
    )

    # The primary keys written this run, by model; tagged objects not among
    # them are deleted at the end.
    keep = collections.defaultdict(set)

    def upsert(cls, lookup, **fields):
        obj = cls.objects.filter(**lookup).first() or cls(**lookup)
        for k, v in fields.items():
            setattr(obj, k, v)
        obj.full_clean()
        obj.save()
        obj.tags.add(tag)
        keep[cls].add(obj.pk)
        return obj

    def named(cls, name, **fields):
        return upsert(cls, {"slug": name.replace(".", "-")}, name=name, **fields)

    sites = {}
    site_nets = []
    for s in want["sites"]:
        sites[s["name"]] = named(Site, s["name"], description=s["domain"])
        site_nets += [(net(s["prefix4"]), s["name"]), (net(s["prefix6"]), s["name"])]

    # A prefix belongs to the site whose own prefix contains it.
    def site_of(p):
        n = net(p)
        for sn, name in site_nets:
            if n.version == sn.version and n.subnet_of(sn):
                return sites[name]
        return None

    def prefix(p, description, status="active", vlan=None):
        upsert(
            Prefix,
            {"prefix": str(net(p)), "vrf": None},
            scope=site_of(p),
            vlan=vlan,
            status=status,
            description=description,
        )

    for p in want["prefixes"]:
        prefix(p["prefix"], p["name"], status="container")

    for s in want["sites"]:
        prefix(s["prefix4"], s["domain"], status="container")
        prefix(s["prefix6"], s["domain"], status="container")

    for v in want["vlans"]:
        vlan = upsert(
            VLAN,
            {"site": site_of(v["prefix4"]), "vid": v["vid"]},
            name=v["name"],
            description=v["role"],
        )
        prefix(v["prefix4"], v["name"], vlan=vlan)
        prefix(v["prefix6"], v["name"], vlan=vlan)

    # NetBox requires a type and a role for every device. The inventory
    # records neither hardware nor a model, so every device shares one type.
    manufacturer = named(Manufacturer, "generic")
    device_type = upsert(
        DeviceType,
        {"manufacturer": manufacturer, "slug": "generic"},
        model="generic",
    )

    devices = {}
    for d in want["devices"]:
        devices[d["name"]] = upsert(
            Device,
            {"name": d["name"], "site": sites[d["site"]]},
            role=named(DeviceRole, d["role"]),
            device_type=device_type,
            description=f"IS-IS {d['isis']}" if d["isis"] else "",
        )

    primary = {}
    circuit_ends = collections.defaultdict(list)
    for i in want["interfaces"]:
        device = devices[i["device"]]
        iface = upsert(
            Interface, {"device": device, "name": i["name"]}, type="virtual"
        )

        if i["mac"]:
            mac = upsert(
                MACAddress, {"mac_address": i["mac"]}, assigned_object=iface
            )
            iface.primary_mac_address = mac
            iface.full_clean()
            iface.save()

        for a in i["addresses"]:
            ip = upsert(
                IPAddress,
                {"address": a["address"], "vrf": None},
                assigned_object=iface,
                role=a.get("role") or "",
                dns_name=a.get("dns") or "",
            )
            # A loopback names the machine; otherwise its first address.
            family = ip.address.version
            key = (device.pk, family)
            if a.get("role") == "loopback" or key not in primary:
                primary[key] = ip

        if "circuit" in i:
            # Both ends of a circuit share its IPv4 /31.
            p = str(net(i["addresses"][0]["address"]))
            circuit_ends[p].append((i, device, iface))

    for d in devices.values():
        d.primary_ip4 = primary.get((d.pk, 4))
        d.primary_ip6 = primary.get((d.pk, 6))
        d.full_clean()
        d.save()

    for a in want["anycast"]:
        upsert(
            IPAddress,
            {"address": a["address"], "vrf": None},
            role="anycast",
            description=a["name"],
        )

    provider = named(Provider, "homelab")
    circuit_type = named(CircuitType, "interconnect")
    for p, ends in circuit_ends.items():
        ends.sort(key=lambda e: (e[1].name, e[2].name))
        plane = ends[0][0]["circuit"]["plane"]
        cid = "-".join(e[1].name for e in ends) + f"-{plane}"
        circuit = upsert(
            Circuit,
            {"provider": provider, "cid": cid},
            type=circuit_type,
            description=p,
        )
        for side, (i, device, iface) in zip("AZ", ends):
            upsert(
                CircuitTermination,
                {"circuit": circuit, "term_side": side},
                termination=sites[i["circuit"]["local"]],
                description=f"{device.name} {iface.name}",
            )

    rir = named(RIR, "dn42", is_private=True)
    ours = upsert(ASN, {"asn": want["asn"]}, rir=rir, description="homelab")
    for site in sites.values():
        site.asns.add(ours)

    by_asn = collections.defaultdict(list)
    for p in want["peers"]:
        by_asn[p["asn"]].append(p)
    for asn, ps in by_asn.items():
        where = ", ".join(sorted(f"{p['device']} {p['interface']}" for p in ps))
        upsert(ASN, {"asn": asn}, rir=rir, description=f"{ps[0]['peer']}: {where}")

    # Dependents before what they depend on.
    for model in (
        CircuitTermination,
        Circuit,
        IPAddress,
        MACAddress,
        Interface,
        Device,
        ASN,
        Prefix,
        VLAN,
        Site,
    ):
        model.objects.filter(tags=tag).exclude(pk__in=keep[model]).delete()

print(
    "netbox-sync: "
    + ", ".join(f"{len(keep[m])} {m._meta.verbose_name_plural}" for m in (
        Site, VLAN, Prefix, Device, Interface, IPAddress, Circuit, ASN
    ))
)
