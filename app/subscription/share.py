import base64
import json
import random
import secrets
from collections import defaultdict
from datetime import datetime as dt
from datetime import timedelta
from typing import TYPE_CHECKING, Iterator, List, Literal, Tuple, Union
from urllib import parse as urlparse

from jdatetime import date as jd

from app.hysteria2 import (
    build_uri as build_hysteria2_uri,
    build_userpass,
    get_client_speed,
    get_obfs_password,
    get_pin_sha256,
    get_port_hop_interval,
    get_public_host as get_hysteria2_public_host,
    get_public_port as get_hysteria2_public_port,
    get_server_name as get_hysteria2_server_name,
)
from app.mtproxy import build_manual_connection as build_mtproxy_manual_connection
from app.protocols import get_inbounds_by_tag
from app import xray
from app.utils.system import get_public_ip, get_public_ipv6, readable_size

from . import *

if TYPE_CHECKING:
    from app.models.user import UserResponse

from config import (
    ACTIVE_STATUS_TEXT,
    DISABLED_STATUS_TEXT,
    EXPIRED_STATUS_TEXT,
    LIMITED_STATUS_TEXT,
    ONHOLD_STATUS_TEXT,
    XRAY_PUBLIC_HOST,
    XRAY_TLS_ALLOW_INSECURE,
)

SERVER_IP = XRAY_PUBLIC_HOST or get_public_ip()
SERVER_IPV6 = get_public_ipv6()

STATUS_EMOJIS = {
    "active": "✅",
    "expired": "⌛",
    "limited": "🪫",
    "disabled": "❌",
    "on_hold": "🔌",
}

STATUS_TEXTS = {
    "active": ACTIVE_STATUS_TEXT,
    "expired": EXPIRED_STATUS_TEXT,
    "limited": LIMITED_STATUS_TEXT,
    "disabled": DISABLED_STATUS_TEXT,
    "on_hold": ONHOLD_STATUS_TEXT,
}


def _render_name_template(template: str, variables: dict) -> str:
    if not template:
        return ""

    try:
        return template.format_map(variables)
    except (KeyError, ValueError):
        return template


def _sorted_inbounds(inbounds: dict) -> List[Tuple]:
    resolved = []
    for protocol, tags in inbounds.items():
        for tag in tags:
            resolved.append((protocol, tag))

    index_dict = {
        proxy: index
        for index, proxy in enumerate(get_inbounds_by_tag().keys())
    }
    return sorted(resolved, key=lambda item: index_dict.get(item[1], float("inf")))


def iter_resolved_hosts(
        inbounds: dict,
        proxies: dict,
        format_variables: dict,
) -> Iterator[dict]:
    available_inbounds_by_tag = get_inbounds_by_tag()
    for protocol, tag in _sorted_inbounds(inbounds):
        settings = proxies.get(protocol)
        if not settings:
            continue

        inbound = available_inbounds_by_tag.get(tag)
        if not inbound:
            continue

        base_variables = defaultdict(
            format_variables.default_factory,
            dict(format_variables),
        )
        base_variables.update(
            {
                "PROTOCOL": protocol.name,
                "protocol": protocol.value,
                "TRANSPORT": inbound["network"],
                "transport": inbound["network"],
                "COUNTRY": tag,
                "country": tag,
                "INBOUND_TAG": tag,
                "inbound_tag": tag,
            }
        )

        if inbound["protocol"] == "hysteria2":
            address = get_hysteria2_public_host()
            port = get_hysteria2_public_port()
            sni = get_hysteria2_server_name()
            if not address or not port:
                continue

            current_variables = defaultdict(
                base_variables.default_factory,
                dict(base_variables),
            )
            current_variables.update(
                {
                    "ADDRESS": address,
                    "address": address,
                    "PORT": port,
                    "port": port,
                    "SNI": sni,
                    "sni": sni,
                    "HOST": "",
                    "host": "",
                    "PATH": "",
                    "path": "",
                }
            )

            remark_template = settings.config_name or "{name}"
            settings_dump = settings.model_dump()
            settings_dump["auth"] = build_userpass(
                str(format_variables["username"]),
                settings.password,
            )
            settings_dump["obfs_password"] = get_obfs_password()
            settings_dump["pin_sha256"] = get_pin_sha256()
            up_mbps, down_mbps = get_client_speed()
            settings_dump["up_mbps"] = up_mbps
            settings_dump["down_mbps"] = down_mbps

            yield {
                "tag": tag,
                "remark": _render_name_template(remark_template, current_variables),
                "address": address,
                "inbound": {
                    **inbound,
                    "port": port,
                    "sni": sni,
                    "host": "",
                    "path": "",
                    "ais": inbound.get("allowinsecure", False),
                    "obfs_password": get_obfs_password(),
                    "hop_interval": get_port_hop_interval(),
                },
                "settings": settings_dump,
                "format_variables": current_variables,
            }
            continue

        for host in xray.hosts.get(tag, []):
            current_variables = defaultdict(
                base_variables.default_factory,
                dict(base_variables),
            )
            host_inbound = inbound.copy()

            sni = ""
            sni_list = host["sni"] or inbound["sni"]
            if sni_list:
                salt = secrets.token_hex(8)
                sni = random.choice(sni_list).replace("*", salt)

            if sids := inbound.get("sids"):
                host_inbound["sid"] = random.choice(sids)

            req_host = ""
            req_host_list = host["host"] or inbound["host"]
            if req_host_list:
                salt = secrets.token_hex(8)
                req_host = random.choice(req_host_list).replace("*", salt)

            address = ""
            address_list = host["address"]
            if address_list:
                salt = secrets.token_hex(8)
                address = random.choice(address_list).replace("*", salt)

            if host["path"] is not None:
                path = host["path"].format_map(current_variables)
            else:
                path = inbound.get("path", "").format_map(current_variables)

            if host.get("use_sni_as_host", False) and sni:
                req_host = sni

            if host["allowinsecure"] is None:
                allow_insecure = inbound.get("allowinsecure", "")
                if allow_insecure in ("", None) and inbound.get("tls") == "tls":
                    allow_insecure = XRAY_TLS_ALLOW_INSECURE
            else:
                allow_insecure = host["allowinsecure"]

            host_inbound.update(
                {
                    "port": host["port"] or inbound["port"],
                    "sni": sni,
                    "host": req_host,
                    "tls": inbound["tls"] if host["tls"] is None else host["tls"],
                    "alpn": host["alpn"] if host["alpn"] else None,
                    "path": path,
                    "fp": host["fingerprint"] or inbound.get("fp", ""),
                    "ais": allow_insecure,
                    "mux_enable": host["mux_enable"],
                    "fragment_setting": host["fragment_setting"],
                    "noise_setting": host["noise_setting"],
                    "random_user_agent": host["random_user_agent"],
                }
            )

            current_variables.update(
                {
                    "ADDRESS": address,
                    "address": address,
                    "PORT": host_inbound["port"],
                    "port": host_inbound["port"],
                    "SNI": sni,
                    "sni": sni,
                    "HOST": req_host,
                    "host": req_host,
                    "PATH": path,
                    "path": path,
                }
            )

            remark_template = settings.config_name or host["remark"] or "{name}"

            yield {
                "tag": tag,
                "remark": _render_name_template(remark_template, current_variables),
                "address": address.format_map(current_variables),
                "inbound": host_inbound,
                "settings": settings.model_dump(),
                "format_variables": current_variables,
            }


def generate_v2ray_links(proxies: dict, inbounds: dict, extra_data: dict, reverse: bool) -> list:
    format_variables = setup_format_variables(extra_data)
    conf = V2rayShareLink()
    return process_inbounds_and_tags(inbounds, proxies, format_variables, conf=conf, reverse=reverse)


def generate_hysteria2_subscription(
        proxies: dict, inbounds: dict, extra_data: dict, reverse: bool
) -> str:
    format_variables = setup_format_variables(extra_data)
    links = []

    for entry in iter_resolved_hosts(inbounds, proxies, format_variables):
        if entry["inbound"]["protocol"] != "hysteria2":
            continue

        link = build_hysteria2_uri(
            username=extra_data.get("username", ""),
            password=entry["settings"]["password"],
            remark=entry["remark"],
            server=entry["address"],
            port=entry["inbound"]["port"],
            sni=entry["inbound"].get("sni", ""),
            insecure=bool(entry["inbound"].get("ais")),
            obfs_password=entry["settings"].get("obfs_password", ""),
            pin_sha256=entry["settings"].get("pin_sha256", ""),
        )
        if link:
            links.append(link)

    if reverse:
        links.reverse()

    return "\n".join(links)


def generate_clash_subscription(
        proxies: dict, inbounds: dict, extra_data: dict, reverse: bool, is_meta: bool = False
) -> str:
    if is_meta is True:
        conf = ClashMetaConfiguration()
    else:
        conf = ClashConfiguration()

    format_variables = setup_format_variables(extra_data)
    return process_inbounds_and_tags(
        inbounds, proxies, format_variables, conf=conf, reverse=reverse
    )


def generate_singbox_subscription(
        proxies: dict, inbounds: dict, extra_data: dict, reverse: bool
) -> str:
    conf = SingBoxConfiguration()

    format_variables = setup_format_variables(extra_data)
    return process_inbounds_and_tags(
        inbounds, proxies, format_variables, conf=conf, reverse=reverse
    )


def generate_outline_subscription(
        proxies: dict, inbounds: dict, extra_data: dict, reverse: bool,
) -> str:
    conf = OutlineConfiguration()

    format_variables = setup_format_variables(extra_data)
    return process_inbounds_and_tags(
        inbounds, proxies, format_variables, conf=conf, reverse=reverse
    )


def generate_v2ray_json_subscription(
        proxies: dict, inbounds: dict, extra_data: dict, reverse: bool,
) -> str:
    conf = V2rayJsonConfig()

    format_variables = setup_format_variables(extra_data)
    return process_inbounds_and_tags(
        inbounds, proxies, format_variables, conf=conf, reverse=reverse
    )


def generate_subscription(
        user: "UserResponse",
        config_format: Literal["v2ray", "clash-meta", "clash", "sing-box", "outline", "v2ray-json", "hysteria2"],
        as_base64: bool,
        reverse: bool,
) -> str:
    kwargs = {
        "proxies": user.proxies,
        "inbounds": user.inbounds,
        "extra_data": user.__dict__,
        "reverse": reverse,
    }

    if config_format == "v2ray":
        config = "\n".join(generate_v2ray_links(**kwargs))
    elif config_format == "clash-meta":
        config = generate_clash_subscription(**kwargs, is_meta=True)
    elif config_format == "clash":
        config = generate_clash_subscription(**kwargs)
    elif config_format == "sing-box":
        config = generate_singbox_subscription(**kwargs)
    elif config_format == "outline":
        config = generate_outline_subscription(**kwargs)
    elif config_format == "v2ray-json":
        config = generate_v2ray_json_subscription(**kwargs)
    elif config_format == "hysteria2":
        config = generate_hysteria2_subscription(**kwargs)
    else:
        raise ValueError(f'Unsupported format "{config_format}"')

    if as_base64:
        config = base64.b64encode(config.encode()).decode()

    return config


def generate_user_links(user: "UserResponse") -> list[str]:
    return generate_v2ray_links(
        proxies=user.proxies,
        inbounds=user.inbounds,
        extra_data=user.model_dump(),
        reverse=False,
    )


def generate_manual_connections(
        proxies: dict,
        inbounds: dict,
        extra_data: dict,
) -> list[dict]:
    format_variables = setup_format_variables(extra_data)
    connections = []

    for entry in iter_resolved_hosts(inbounds, proxies, format_variables):
        if entry["inbound"]["protocol"] != "mtproto":
            if entry["inbound"]["protocol"] != "hysteria2":
                continue

            hy2_link = build_hysteria2_uri(
                username=extra_data.get("username", ""),
                password=entry["settings"]["password"],
                remark=entry["remark"],
                server=entry["address"],
                port=entry["inbound"]["port"],
                sni=entry["inbound"].get("sni", ""),
                insecure=bool(entry["inbound"].get("ais")),
                obfs_password=entry["settings"].get("obfs_password", ""),
                pin_sha256=entry["settings"].get("pin_sha256", ""),
            )

            connections.append(
                {
                    "title": entry["remark"],
                    "protocol": "HYSTERIA2",
                    "server": entry["address"],
                    "port": entry["inbound"]["port"],
                    "auth": entry["settings"]["auth"],
                    "username": extra_data.get("username", ""),
                    "password": entry["settings"]["password"],
                    "sni": entry["inbound"].get("sni", ""),
                    "obfs_password": entry["settings"].get("obfs_password", ""),
                    "insecure": bool(entry["inbound"].get("ais")),
                    "pin_sha256": entry["settings"].get("pin_sha256", ""),
                    "share_url": hy2_link,
                }
            )
            continue

        secret = entry["settings"]["secret"]
        server = entry["address"]
        port = entry["inbound"]["port"]
        if isinstance(port, str):
            port = port.split(",")[0].strip()

        encoded_server = urlparse.quote(str(server), safe="")
        tg_link = f"tg://proxy?server={encoded_server}&port={port}&secret={secret}"
        web_link = f"https://t.me/proxy?server={encoded_server}&port={port}&secret={secret}"

        connections.append(
            {
                "title": entry["remark"],
                "protocol": "MTPROTO",
                "server": server,
                "port": port,
                "secret": secret,
                "username": extra_data.get("username", ""),
                "telegram_url": tg_link,
                "share_url": web_link,
            }
        )

    standalone_mtproxy = build_mtproxy_manual_connection()
    if standalone_mtproxy:
        connections.append(standalone_mtproxy)

    return connections


def _decode_vmess_payload(link: str) -> dict:
    encoded = link.removeprefix("vmess://")
    encoded += "=" * ((4 - len(encoded) % 4) % 4)
    return json.loads(base64.b64decode(encoded.encode()).decode("utf-8"))


def get_link_title(link: str, fallback: str = "") -> str:
    try:
        if link.startswith("vmess://"):
            payload = _decode_vmess_payload(link)
            return payload.get("ps") or fallback

        parts = urlparse.urlsplit(link)
        return urlparse.unquote(parts.fragment or fallback)
    except Exception:
        return fallback


def get_link_protocol(link: str) -> str:
    protocol = link.split("://", 1)[0].lower()
    if protocol == "hy2":
        return "HYSTERIA2"
    return protocol.upper()


def build_subscription_page_context(user: "UserResponse", base_url: str) -> dict:
    base_url = base_url.rstrip("/")
    raw_links = generate_user_links(user)
    manual_connections = generate_manual_connections(
        proxies=user.proxies,
        inbounds=user.inbounds,
        extra_data=user.model_dump(),
    )

    connection_links = [
        {
            "title": get_link_title(link, f"{get_link_protocol(link)} {index}"),
            "protocol": get_link_protocol(link),
            "link": link,
        }
        for index, link in enumerate(raw_links, start=1)
    ]

    client_links = [
        {
            "title": "Universal",
            "subtitle": "Explicit V2Ray export endpoint",
            "url": f"{base_url}/v2ray",
            "format": "v2ray",
        },
        {
            "title": "Clash Meta",
            "subtitle": "Mihomo / Clash Meta profile",
            "url": f"{base_url}/clash-meta",
            "format": "clash-meta",
        },
        {
            "title": "Clash",
            "subtitle": "Classic Clash profile",
            "url": f"{base_url}/clash",
            "format": "clash",
        },
        {
            "title": "Sing-box",
            "subtitle": "JSON export for sing-box clients",
            "url": f"{base_url}/sing-box",
            "format": "sing-box",
        },
        {
            "title": "Outline",
            "subtitle": "Shadowsocks-only export",
            "url": f"{base_url}/outline",
            "format": "outline",
        },
        {
            "title": "V2Ray JSON",
            "subtitle": "Structured JSON for supported V2Ray clients",
            "url": f"{base_url}/v2ray-json",
            "format": "v2ray-json",
        },
    ]

    if any(item["protocol"] == "HYSTERIA2" for item in manual_connections):
        client_links.append(
            {
                "title": "Hysteria2",
                "subtitle": "Direct hy2 links for Hysteria2 clients",
                "url": f"{base_url}/hysteria2",
                "format": "hysteria2",
            }
        )

    return {
        "user": user,
        "subscription_url": base_url,
        "client_links": client_links,
        "connection_links": connection_links,
        "manual_connections": manual_connections,
    }


def format_time_left(seconds_left: int) -> str:
    if not seconds_left or seconds_left <= 0:
        return "∞"

    minutes, seconds = divmod(seconds_left, 60)
    hours, minutes = divmod(minutes, 60)
    days, hours = divmod(hours, 24)
    months, days = divmod(days, 30)

    result = []
    if months:
        result.append(f"{months}m")
    if days:
        result.append(f"{days}d")
    if hours and (days < 7):
        result.append(f"{hours}h")
    if minutes and not (months or days):
        result.append(f"{minutes}m")
    if seconds and not (months or days):
        result.append(f"{seconds}s")
    return " ".join(result)


def setup_format_variables(extra_data: dict) -> dict:
    from app.models.user import UserStatus

    user_status = extra_data.get("status")
    expire_timestamp = extra_data.get("expire")
    on_hold_expire_duration = extra_data.get("on_hold_expire_duration")
    now = dt.utcnow()
    now_ts = now.timestamp()

    if user_status != UserStatus.on_hold:
        if expire_timestamp is not None and expire_timestamp >= 0:
            seconds_left = expire_timestamp - int(dt.utcnow().timestamp())
            expire_datetime = dt.fromtimestamp(expire_timestamp)
            expire_date = expire_datetime.date()
            jalali_expire_date = jd.fromgregorian(
                year=expire_date.year, month=expire_date.month, day=expire_date.day
            ).strftime("%Y-%m-%d")
            if now_ts < expire_timestamp:
                days_left = (expire_datetime - dt.utcnow()).days + 1
                time_left = format_time_left(seconds_left)
            else:
                days_left = "0"
                time_left = "0"

        else:
            days_left = "∞"
            time_left = "∞"
            expire_date = "∞"
            jalali_expire_date = "∞"
    else:
        if on_hold_expire_duration is not None and on_hold_expire_duration >= 0:
            days_left = timedelta(seconds=on_hold_expire_duration).days
            time_left = format_time_left(on_hold_expire_duration)
            expire_date = "-"
            jalali_expire_date = "-"
        else:
            days_left = "∞"
            time_left = "∞"
            expire_date = "∞"
            jalali_expire_date = "∞"

    if extra_data.get("data_limit"):
        data_limit = readable_size(extra_data["data_limit"])
        data_left = extra_data["data_limit"] - extra_data["used_traffic"]
        if data_left < 0:
            data_left = 0
        data_left = readable_size(data_left)
    else:
        data_limit = "∞"
        data_left = "∞"

    used_traffic = readable_size(extra_data.get("used_traffic"))
    username = extra_data.get("username", "{USERNAME}")
    status_emoji = STATUS_EMOJIS.get(extra_data.get("status")) or ""
    status_text = STATUS_TEXTS.get(extra_data.get("status")) or ""

    format_variables = defaultdict(
        lambda: "<missing>",
        {
            "SERVER_IP": SERVER_IP,
            "SERVER_IPV6": SERVER_IPV6,
            "server_ip": SERVER_IP,
            "server_ipv6": SERVER_IPV6,
            "NAME": username,
            "name": username,
            "USERNAME": username,
            "username": username,
            "DATA_USAGE": used_traffic,
            "data_usage": used_traffic,
            "DATA_LIMIT": data_limit,
            "data_limit": data_limit,
            "DATA_LEFT": data_left,
            "data_left": data_left,
            "DAYS_LEFT": days_left,
            "days_left": days_left,
            "EXPIRE_DATE": expire_date,
            "expire_date": expire_date,
            "JALALI_EXPIRE_DATE": jalali_expire_date,
            "jalali_expire_date": jalali_expire_date,
            "TIME_LEFT": time_left,
            "time_left": time_left,
            "STATUS_EMOJI": status_emoji,
            "status_emoji": status_emoji,
            "STATUS_TEXT": status_text,
            "status_text": status_text,
            "PROTOCOL": "{PROTOCOL}",
            "protocol": "{protocol}",
            "TRANSPORT": "{TRANSPORT}",
            "transport": "{transport}",
            "COUNTRY": "{COUNTRY}",
            "country": "{country}",
            "INBOUND_TAG": "{INBOUND_TAG}",
            "inbound_tag": "{inbound_tag}",
            "ADDRESS": "{ADDRESS}",
            "address": "{address}",
            "PORT": "{PORT}",
            "port": "{port}",
            "SNI": "{SNI}",
            "sni": "{sni}",
            "HOST": "{HOST}",
            "host": "{host}",
            "PATH": "{PATH}",
            "path": "{path}",
        },
    )

    return format_variables


def process_inbounds_and_tags(
        inbounds: dict,
        proxies: dict,
        format_variables: dict,
        conf: Union[
            V2rayShareLink,
            V2rayJsonConfig,
            SingBoxConfiguration,
            ClashConfiguration,
            ClashMetaConfiguration,
            OutlineConfiguration
        ],
        reverse=False,
) -> Union[List, str]:
    for entry in iter_resolved_hosts(inbounds, proxies, format_variables):
        conf.add(
            remark=entry["remark"],
            address=entry["address"],
            inbound=entry["inbound"],
            settings=entry["settings"],
        )

    return conf.render(reverse=reverse)


def encode_title(text: str) -> str:
    return f"base64:{base64.b64encode(text.encode()).decode()}"
