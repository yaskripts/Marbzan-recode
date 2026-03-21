from __future__ import annotations

from urllib.parse import quote

from app.utils.system import get_public_ip
from config import (
    MTPROXY_ENABLED,
    MTPROXY_FAKE_TLS_DOMAIN,
    MTPROXY_NAME,
    MTPROXY_PORT,
    MTPROXY_PUBLIC_HOST,
    MTPROXY_RAW_SECRET,
    MTPROXY_SECRET,
)


def is_enabled() -> bool:
    return MTPROXY_ENABLED and bool(get_public_host()) and bool(get_secret())


def get_public_host() -> str:
    return MTPROXY_PUBLIC_HOST or get_public_ip()


def get_port() -> int:
    return MTPROXY_PORT


def _build_public_secret(raw_secret: str, fake_tls_domain: str) -> str:
    if not raw_secret or not fake_tls_domain:
        return ""
    return f"ee{raw_secret.lower()}{fake_tls_domain.encode('utf-8').hex()}"


def get_secret() -> str:
    if MTPROXY_SECRET:
        return MTPROXY_SECRET.strip().lower()
    return _build_public_secret(MTPROXY_RAW_SECRET.strip(), MTPROXY_FAKE_TLS_DOMAIN.strip())


def get_fake_tls_domain() -> str:
    return MTPROXY_FAKE_TLS_DOMAIN.strip()


def build_tg_link(
    server: str | None = None,
    port: int | None = None,
    secret: str | None = None,
) -> str | None:
    if not is_enabled():
        return None

    server = server or get_public_host()
    port = port or get_port()
    secret = secret or get_secret()
    if not server or not port or not secret:
        return None

    return (
        f"tg://proxy?server={quote(str(server), safe='')}"
        f"&port={port}&secret={quote(secret, safe='')}"
    )


def build_web_link(
    server: str | None = None,
    port: int | None = None,
    secret: str | None = None,
) -> str | None:
    if not is_enabled():
        return None

    server = server or get_public_host()
    port = port or get_port()
    secret = secret or get_secret()
    if not server or not port or not secret:
        return None

    return (
        f"https://t.me/proxy?server={quote(str(server), safe='')}"
        f"&port={port}&secret={quote(secret, safe='')}"
    )


def build_manual_connection() -> dict | None:
    if not is_enabled():
        return None

    return {
        "title": MTPROXY_NAME,
        "protocol": "MTPROXY",
        "server": get_public_host(),
        "port": get_port(),
        "secret": get_secret(),
        "fake_tls_domain": get_fake_tls_domain(),
        "telegram_url": build_tg_link(),
        "share_url": build_web_link(),
    }
