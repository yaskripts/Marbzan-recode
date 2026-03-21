from __future__ import annotations

from functools import lru_cache
from hashlib import sha256
from pathlib import Path
from typing import Any
from urllib.parse import quote, urlencode

from cryptography import x509
from cryptography.hazmat.primitives import serialization

from app.models.proxy import ProxyTypes
from app.utils.system import get_public_ip
from config import (
    HYSTERIA2_AUTH_SECRET,
    HYSTERIA2_CLIENT_DOWN_Mbps,
    HYSTERIA2_CLIENT_UP_Mbps,
    HYSTERIA2_ENABLED,
    HYSTERIA2_HOP_INTERVAL,
    HYSTERIA2_INSECURE,
    HYSTERIA2_OBFS_PASSWORD,
    HYSTERIA2_PIN_SHA256,
    HYSTERIA2_PORT,
    HYSTERIA2_PORTS,
    HYSTERIA2_PUBLIC_HOST,
    HYSTERIA2_SNI,
    HYSTERIA2_TAG,
    HYSTERIA2_TLS_CERT,
)


def is_enabled() -> bool:
    return HYSTERIA2_ENABLED and bool(get_public_host())


def get_public_host() -> str:
    return HYSTERIA2_PUBLIC_HOST or HYSTERIA2_SNI or get_public_ip()


def get_server_name() -> str:
    return HYSTERIA2_SNI or HYSTERIA2_PUBLIC_HOST or get_public_host()


def get_public_port() -> int | str:
    return HYSTERIA2_PORTS.strip() or HYSTERIA2_PORT


def get_auth_path() -> str:
    if HYSTERIA2_AUTH_SECRET:
        return f"/api/hysteria2/{HYSTERIA2_AUTH_SECRET}/auth"
    return "/api/hysteria2/auth"


def build_userpass(username: str, password: str) -> str:
    return f"{username}:{password}"


def _format_host_for_uri(host: str) -> str:
    if ":" in host and not host.startswith("["):
        return f"[{host}]"
    return host


@lru_cache(maxsize=1)
def get_pin_sha256() -> str:
    if HYSTERIA2_PIN_SHA256:
        return HYSTERIA2_PIN_SHA256

    if not HYSTERIA2_TLS_CERT:
        return ""

    cert_path = Path(HYSTERIA2_TLS_CERT)
    if not cert_path.is_file():
        return ""

    try:
        cert = x509.load_pem_x509_certificate(cert_path.read_bytes())
        digest = sha256(
            cert.public_bytes(serialization.Encoding.DER)
        ).hexdigest().upper()
        return ":".join(digest[i:i + 2] for i in range(0, len(digest), 2))
    except Exception:
        return ""


def get_virtual_inbounds_by_protocol() -> dict[str, list[dict[str, Any]]]:
    if not is_enabled():
        return {}

    inbound = {
        "tag": HYSTERIA2_TAG,
        "protocol": ProxyTypes.Hysteria2.value,
        "port": get_public_port(),
        "network": "udp",
        "tls": "tls",
        "sni": [get_server_name()] if get_server_name() else [],
        "host": [],
        "path": "",
        "header_type": "",
        "is_fallback": False,
        "allowinsecure": HYSTERIA2_INSECURE,
        "alpn": "h3",
    }
    return {ProxyTypes.Hysteria2.value: [inbound]}


def get_virtual_inbounds_by_tag() -> dict[str, dict[str, Any]]:
    return {
        inbound["tag"]: inbound
        for inbounds in get_virtual_inbounds_by_protocol().values()
        for inbound in inbounds
    }


def get_client_speed() -> tuple[int, int]:
    return HYSTERIA2_CLIENT_UP_Mbps, HYSTERIA2_CLIENT_DOWN_Mbps


def get_port_hop_interval() -> str:
    return HYSTERIA2_HOP_INTERVAL


def get_obfs_password() -> str:
    return HYSTERIA2_OBFS_PASSWORD


def build_uri(
    username: str,
    password: str,
    remark: str,
    *,
    server: str | None = None,
    port: int | str | None = None,
    sni: str | None = None,
    insecure: bool | None = None,
    obfs_password: str | None = None,
    pin_sha256: str | None = None,
) -> str | None:
    if not is_enabled():
        return None

    server = server or get_public_host()
    port = port or get_public_port()
    sni = sni if sni is not None else get_server_name()
    insecure = HYSTERIA2_INSECURE if insecure is None else insecure
    obfs_password = HYSTERIA2_OBFS_PASSWORD if obfs_password is None else obfs_password
    pin_sha256 = pin_sha256 if pin_sha256 is not None else get_pin_sha256()

    if not server or not port:
        return None

    auth = quote(build_userpass(username, password), safe=":")
    params = {}
    if sni:
        params["sni"] = sni
    if obfs_password:
        params["obfs"] = "salamander"
        params["obfs-password"] = obfs_password
    if insecure:
        params["insecure"] = "1"
    if pin_sha256:
        params["pinSHA256"] = pin_sha256

    query = urlencode(params)
    query_part = f"?{query}" if query else ""
    return (
        f"hy2://{auth}@{_format_host_for_uri(server)}:{port}/{query_part}"
        f"#{quote(remark)}"
    )
