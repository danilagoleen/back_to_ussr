#!/usr/bin/env python3
import base64
import urllib.parse


def decode_subscription(text: str):
    text = text.strip()
    if not text:
        return []
    if "vless://" in text:
        return [line.strip() for line in text.splitlines() if line.strip().startswith("vless://")]

    compact = text.replace("\n", "").replace("\r", "")
    candidates = []
    normal = compact
    urlsafe = compact.replace("-", "+").replace("_", "/")
    for base in (normal, urlsafe):
        candidates.extend([base, base + "=", base + "==", base + "==="])

    for cand in candidates:
        try:
            decoded = base64.b64decode(cand, validate=False).decode("utf-8", errors="ignore")
        except Exception:
            continue
        lines = [line.strip() for line in decoded.splitlines() if line.strip().startswith("vless://")]
        if lines:
            return lines
    return []


def parse_vless(uri: str):
    assert uri.lower().startswith("vless://")
    body = uri[len("vless://"):]
    user, rest = body.split("@", 1)
    host_part = rest.split("#", 1)[0]
    name = urllib.parse.unquote(rest.split("#", 1)[1]) if "#" in rest else ""
    host_port, query = (host_part.split("?", 1) + [""])[:2]
    host, port_s = host_port.rsplit(":", 1)
    qs = urllib.parse.parse_qs(query)
    return {
        "name": name or f"{host}:{port_s}",
        "uuid": user,
        "server": host,
        "port": int(port_s),
        "sni": qs.get("sni", [""])[0],
        "pbk": qs.get("pbk", [""])[0],
        "sid": qs.get("sid", [""])[0],
        "fp": qs.get("fp", ["chrome"])[0],
        "flow": qs.get("flow", [""])[0],
    }


def test_decode_plain():
    src = "vless://id@host:443?security=reality&pbk=a&sid=b#US\n"
    out = decode_subscription(src)
    assert len(out) == 1
    assert out[0].startswith("vless://")


def test_decode_base64():
    raw = "vless://id@host:443?security=reality&pbk=a&sid=b#US\n"
    encoded = base64.b64encode(raw.encode()).decode()
    out = decode_subscription(encoded)
    assert len(out) == 1


def test_parse_vless():
    uri = "vless://abc-uuid@demo.example:8443?security=reality&flow=xtls-rprx-vision&sni=rbc.ru&fp=random&pbk=PUBLIC&sid=123#NL"
    node = parse_vless(uri)
    assert node["uuid"] == "abc-uuid"
    assert node["server"] == "demo.example"
    assert node["port"] == 8443
    assert node["name"] == "NL"
    assert node["pbk"] == "PUBLIC"
    assert node["sid"] == "123"
