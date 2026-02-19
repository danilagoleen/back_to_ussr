#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC="$ROOT/src/main.swift"
BUILD="$ROOT/build"
DIST="$ROOT/dist"
APP="$DIST/BACK_TO_USSR.app"
BIN_DIR="$APP/Contents/MacOS"
RES_DIR="$APP/Contents/Resources"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
MODULE_CACHE="/tmp/swift-module-cache-back-to-ussr"
ICONSET_DIR="$BUILD/AppIcon.iconset"
ICON_SWIFT="$BUILD/generate_icon.swift"
ICON_ICNS="$RES_DIR/AppIcon.icns"

SINGBOX_URL="https://github.com/SagerNet/sing-box/releases/download/v1.9.3/sing-box-1.9.3-darwin-amd64.tar.gz"
SINGBOX_TGZ="$BUILD/sing-box-1.9.3-darwin-amd64.tar.gz"
SINGBOX_EXTRACT="$BUILD/singbox_extract"
SINGBOX_BIN="$SINGBOX_EXTRACT/sing-box-1.9.3-darwin-amd64/sing-box"

MUSIC_SRC_DIR="/Users/danilagulin/Documents/ussr_vpn/music/compress"
HERO_IMAGE_SRC="/Users/danilagulin/Documents/ussr_vpn/logo_ussr/image.jpg_attr1-topaz-upscale-4x_attr1_subject1.png"

mkdir -p "$BUILD" "$DIST" "$MODULE_CACHE"
rm -rf "$APP" "$SINGBOX_EXTRACT"
mkdir -p "$BIN_DIR" "$RES_DIR"

echo "[1/5] Download sing-box amd64..."
curl -fL "$SINGBOX_URL" -o "$SINGBOX_TGZ"
mkdir -p "$SINGBOX_EXTRACT"
tar -xzf "$SINGBOX_TGZ" -C "$SINGBOX_EXTRACT"
if [[ ! -x "$SINGBOX_BIN" ]]; then
  echo "[ERROR] sing-box binary not found after extraction"
  exit 1
fi
cp "$SINGBOX_BIN" "$RES_DIR/sing-box"
chmod +x "$RES_DIR/sing-box"

echo "[2/5] Compile BACK_TO_USSR x86_64..."
SWIFT_MODULECACHE_PATH="$MODULE_CACHE" CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" \
swiftc \
  -target x86_64-apple-macos11.0 \
  -sdk "$SDK" \
  -O \
  "$SRC" \
  -o "$BIN_DIR/BACK_TO_USSR"

echo "[3/5] Create Info.plist..."
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>BACK_TO_USSR</string>
  <key>CFBundleDisplayName</key><string>BACK_TO_USSR</string>
  <key>CFBundleIdentifier</key><string>com.back.to.ussr</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>BACK_TO_USSR</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>11.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

echo "[4/5] Build app icon + add bundled tracks/assets..."
rm -rf "$ICONSET_DIR"
mkdir -p "$ICONSET_DIR"
cat > "$ICON_SWIFT" <<'SWIFT'
import AppKit
import Foundation

let args = CommandLine.arguments
guard args.count >= 2 else { exit(1) }
let outDir = args[1]
let fm = FileManager.default
try? fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func makeIcon(_ px: Int, _ name: String) {
    guard let sym = NSImage(systemSymbolName: "star.fill", accessibilityDescription: nil) else { return }
    let cfg = NSImage.SymbolConfiguration(pointSize: CGFloat(px) * 0.74, weight: .bold)
    guard let img = sym.withSymbolConfiguration(cfg) else { return }

    let canvas = NSImage(size: NSSize(width: px, height: px))
    canvas.lockFocus()
    NSColor.clear.setFill()
    NSBezierPath(rect: NSRect(x: 0, y: 0, width: px, height: px)).fill()
    NSColor.white.set()
    let w = CGFloat(px) * 0.78
    let h = CGFloat(px) * 0.78
    let x = (CGFloat(px) - w) / 2
    let y = (CGFloat(px) - h) / 2
    img.draw(in: NSRect(x: x, y: y, width: w, height: h))
    canvas.unlockFocus()

    guard let tiff = canvas.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { return }
    let path = (outDir as NSString).appendingPathComponent(name)
    try? png.write(to: URL(fileURLWithPath: path))
}

makeIcon(16, "icon_16x16.png")
makeIcon(32, "icon_16x16@2x.png")
makeIcon(32, "icon_32x32.png")
makeIcon(64, "icon_32x32@2x.png")
makeIcon(128, "icon_128x128.png")
makeIcon(256, "icon_128x128@2x.png")
makeIcon(256, "icon_256x256.png")
makeIcon(512, "icon_256x256@2x.png")
makeIcon(512, "icon_512x512.png")
makeIcon(1024, "icon_512x512@2x.png")
SWIFT
swift "$ICON_SWIFT" "$ICONSET_DIR"
iconutil -c icns "$ICONSET_DIR" -o "$ICON_ICNS"

TRACK_COUNT=0
if [[ -d "$MUSIC_SRC_DIR" ]]; then
  while IFS= read -r -d '' f; do
    name="$(basename "$f")"
    cp "$f" "$RES_DIR/$name"
    TRACK_COUNT=$((TRACK_COUNT + 1))
  done < <(find "$MUSIC_SRC_DIR" -maxdepth 1 -type f -name "*.mp3" -print0 | sort -z)
  echo "Bundled tracks: $TRACK_COUNT"
else
  echo "No music dir found: $MUSIC_SRC_DIR"
fi

if [[ -f "$HERO_IMAGE_SRC" ]]; then
  cp "$HERO_IMAGE_SRC" "$RES_DIR/subscription_hero.png"
  echo "Bundled subscription hero image"
else
  echo "No hero image found at $HERO_IMAGE_SRC"
fi

echo "[5/5] Ad-hoc sign..."
xattr -cr "$APP" || true
codesign --force --deep --sign - "$APP"

file "$BIN_DIR/BACK_TO_USSR"

echo "Done: $APP"
