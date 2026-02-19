#!/usr/bin/env python3
import base64
import os
import sys
import urllib.request

DEFAULT_URLS = [
    "https://example.com/subscription-1",
    "https://example.com/subscription-2",
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
    # Priority:
    # 1) CLI args: python live_subscription_check.py <url1> <url2> ...
    # 2) SUBSCRIPTION_URLS env var (newline/comma separated)
    # 3) Safe placeholders (will normally fail and remind user to pass real URLs)
    urls = sys.argv[1:]
    if not urls:
        env_urls = os.getenv("SUBSCRIPTION_URLS", "").strip()
        if env_urls:
            urls = [x.strip() for x in env_urls.replace("\n", ",").split(",") if x.strip()]
    if not urls:
        urls = DEFAULT_URLS

    ok = 0
    for url in urls:
        try:
            payload = fetch(url)
            nodes = decode_payload(payload)
            print(f"{url} -> {len(nodes)} nodes")
            if nodes:
                ok += 1
        except Exception as e:
            print(f"{url} -> ERROR: {e}")

    if urls == DEFAULT_URLS:
        print("INFO: pass real URLs via args or SUBSCRIPTION_URLS env var")

    return 0 if ok > 0 else 2


if __name__ == "__main__":
    sys.exit(main())
