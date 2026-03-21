from __future__ import annotations

from copy import deepcopy
from typing import Any

from app import xray
from app.hysteria2 import get_virtual_inbounds_by_protocol, get_virtual_inbounds_by_tag


def get_inbounds_by_protocol() -> dict[str, list[dict[str, Any]]]:
    merged = {
        protocol: [deepcopy(inbound) for inbound in inbounds]
        for protocol, inbounds in xray.config.inbounds_by_protocol.items()
    }
    for protocol, inbounds in get_virtual_inbounds_by_protocol().items():
        merged.setdefault(protocol, [])
        merged[protocol].extend(deepcopy(inbound) for inbound in inbounds)
    return merged


def get_inbounds_by_tag() -> dict[str, dict[str, Any]]:
    merged = {
        tag: deepcopy(inbound)
        for tag, inbound in xray.config.inbounds_by_tag.items()
    }
    for tag, inbound in get_virtual_inbounds_by_tag().items():
        merged[tag] = deepcopy(inbound)
    return merged


def is_protocol_enabled(proxy_type) -> bool:
    return bool(get_inbounds_by_protocol().get(proxy_type))
