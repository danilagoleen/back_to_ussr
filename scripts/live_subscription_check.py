#!/usr/bin/env python3
import base64
import sys
import urllib.request

URLS = [
    "https://proxyliberty.ru/connection/subs/48bb9885-5a2a-4129-9347-3e946e7ca5b9",
    "https://proxyliberty.ru/connection/tunnel/48bb9885-5a2a-4129-9347-3e946e7ca5b9",
    "https://proxyliberty.ru/connection/test_proxies_subs/48bb9885-5a2a-4129-9347-3e946e7ca5b9",
]


def decode_payload(text: str):
    text = text.strip()
    if "vless://" in text:
        return [line.strip() for line in text.splitlines() if line.strip().startswith("vless://")]

    compact = text.replace("\n", "").replace("\r", "")
    candidates = [compact, compact + "=", compact + "==", compact + "===", compact.replace("-", "+").replace("_", "/")]
    for cand in candidates:
        try:
            decoded = base64.b64decode(cand, validate=False).decode("utf-8", errors="ignore")
        except Exception:
            continue
        lines = [line.strip() for line in decoded.splitlines() if line.strip().startswith("vless://")]
        if lines:
            return lines
    return []


def fetch(url: str) -> str:
    req = urllib.request.Request(url, headers={"User-Agent": "BACK_TO_USSR/test"})
    with urllib.request.urlopen(req, timeout=20) as r:
        return r.read().decode("utf-8", errors="ignore")


def main() -> int:
    ok = 0
    for url in URLS:
        try:
            payload = fetch(url)
            nodes = decode_payload(payload)
            print(f"{url} -> {len(nodes)} nodes")
            if nodes:
                ok += 1
        except Exception as e:
            print(f"{url} -> ERROR: {e}")

    return 0 if ok > 0 else 2


if __name__ == "__main__":
    sys.exit(main())
