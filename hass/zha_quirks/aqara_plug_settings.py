"""Aqara lumi.plug.maus01 with writable Basic attribute 0xFFF0, which
takes outage memory and the night LED, written at each ZHA configuration.
"""

import logging
from typing import Final

from zhaquirks.const import ENDPOINTS, INPUT_CLUSTERS
from zhaquirks.xiaomi import BasicCluster
from zhaquirks.xiaomi.aqara.plug_maus01 import Plug
from zigpy import types as t
from zigpy.zcl import foundation
from zigpy.zcl.foundation import ZCLAttributeDef

_LOGGER = logging.getLogger(__name__)

# Written at each configuration; the plug cannot report them.
OUTAGE_MEMORY_ON: Final = bytes.fromhex("aa8005d14700011001")
NIGHT_LED_OFF: Final = bytes.fromhex("aa8005d14700031000")


class HexOctetString(t.LVBytes):
    """An octet string that also takes the hex string a ZHA service call
    passes, which ZHA hands to the attribute's type unconverted."""

    def __new__(cls, value=b""):
        if isinstance(value, str):
            value = bytes.fromhex(value)
        return super().__new__(cls, value)


class SettingsBasicCluster(BasicCluster):
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

    async def apply_custom_configuration(self, *args, **kwargs):
        """Write each setting. A raised error would skip ZHA's bindings and
        reporting, so failures are only logged."""
        for value in (OUTAGE_MEMORY_ON, NIGHT_LED_OFF):
            try:
                result = await self.write_attributes(
                    {self.AttributeDefs.lumi_config.id: value}
                )
            except Exception:  # noqa: BLE001
                _LOGGER.warning(
                    "%s: writing 0xFFF0 %s failed",
                    self.endpoint.device.ieee,
                    value.hex(),
                    exc_info=True,
                )
                continue
            if result[0][0].status != foundation.Status.SUCCESS:
                _LOGGER.warning(
                    "%s: writing 0xFFF0 %s returned %s",
                    self.endpoint.device.ieee,
                    value.hex(),
                    result[0],
                )


_ep1 = Plug.replacement[ENDPOINTS][1]


class SettingsPlug(Plug):
    """lumi.plug.maus01 with a writable Basic attribute 0xFFF0, set at
    configuration."""

    replacement = {
        **Plug.replacement,
        ENDPOINTS: {
            **Plug.replacement[ENDPOINTS],
            1: {
                **_ep1,
                INPUT_CLUSTERS: [
                    SettingsBasicCluster if c is BasicCluster else c
                    for c in _ep1[INPUT_CLUSTERS]
                ],
            },
        },
    }
