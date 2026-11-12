"""Power outage memory on the Aqara US smart plug, lumi.plug.maus01.

The upstream quirk with its Basic cluster swapped for one that defines
manufacturer-specific attribute 0xFFF0, through which the plug takes this
setting, so that zha.set_zigbee_cluster_attribute can write it. Every other
cluster is the upstream quirk's.
"""

from typing import Final

from zhaquirks.const import ENDPOINTS, INPUT_CLUSTERS
from zhaquirks.xiaomi import BasicCluster
from zhaquirks.xiaomi.aqara.plug_maus01 import Plug
from zigpy import types as t
from zigpy.zcl.foundation import ZCLAttributeDef


class HexOctetString(t.LVBytes):
    """An octet string that also takes the hex string a ZHA service call
    passes, which ZHA hands to the attribute's type unconverted."""

    def __new__(cls, value=b""):
        if isinstance(value, str):
            value = bytes.fromhex(value)
        return super().__new__(cls, value)


class OutageMemoryBasicCluster(BasicCluster):
    """Xiaomi Basic cluster with the plug's configuration attribute."""

    class AttributeDefs(BasicCluster.AttributeDefs):
        """Cluster attributes.

        zigpy takes a write's manufacturer code from the attribute's
        definition or the device's node descriptor, not from the
        service call, so the definition carries Lumi's code.
        """

        lumi_config: Final = ZCLAttributeDef(
            id=0xFFF0,
            type=HexOctetString,
            is_manufacturer_specific=True,
            manufacturer_code=0x115F,
        )


_ep1 = Plug.replacement[ENDPOINTS][1]


class OutageMemoryPlug(Plug):
    """lumi.plug.maus01 with a writable Basic attribute 0xFFF0."""

    replacement = {
        **Plug.replacement,
        ENDPOINTS: {
            **Plug.replacement[ENDPOINTS],
            1: {
                **_ep1,
                INPUT_CLUSTERS: [
                    OutageMemoryBasicCluster if c is BasicCluster else c
                    for c in _ep1[INPUT_CLUSTERS]
                ],
            },
        },
    }
