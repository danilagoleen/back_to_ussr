#!/usr/bin/env python3
import struct
import sys
from pathlib import Path


TYPE_BY_SIZE = {
    16: "icp4",
    32: "icp5",
    64: "icp6",
    128: "ic07",
    256: "ic08",
    512: "ic09",
    1024: "ic10",
}


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: build_icns.py <iconset_dir> <output.icns>", file=sys.stderr)
        return 2

    iconset_dir = Path(sys.argv[1])
    output_path = Path(sys.argv[2])

    chunks: list[bytes] = []
    for size, icon_type in TYPE_BY_SIZE.items():
        png_path = iconset_dir / f"icon_{size}x{size}.png"
        if not png_path.exists():
            print(f"missing required icon: {png_path}", file=sys.stderr)
            return 1
        png_bytes = png_path.read_bytes()
        chunk = icon_type.encode("ascii") + struct.pack(">I", len(png_bytes) + 8) + png_bytes
        chunks.append(chunk)

    body = b"".join(chunks)
    payload = b"icns" + struct.pack(">I", len(body) + 8) + body
    output_path.write_bytes(payload)
    print(output_path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
