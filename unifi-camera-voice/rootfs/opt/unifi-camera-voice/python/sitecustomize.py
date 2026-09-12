"""Keep Linux Voice Assistant's ESPHome identity stable across containers."""

import os
import re

stable_mac = os.environ.get("LVA_MAC_ADDRESS")

if stable_mac:
    if not re.fullmatch(r"[0-9a-f]{2}(?::[0-9a-f]{2}){5}", stable_mac):
        raise RuntimeError("LVA_MAC_ADDRESS must be a lowercase MAC address")

    import getmac

    getmac.get_mac_address = lambda *args, **kwargs: stable_mac
