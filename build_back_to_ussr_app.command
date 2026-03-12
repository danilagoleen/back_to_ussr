#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC="$ROOT/src/main.swift"
CORE_SRC=("$ROOT"/src/Core/*.swift)
BUILD="$ROOT/build"
DIST="$ROOT/dist"
APP="$DIST/BACK_TO_USSR.app"
BIN_DIR="$APP/Contents/MacOS"
RES_DIR="$APP/Contents/Resources"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
MODULE_CACHE="/tmp/swift-module-cache-back-to-ussr"
HOME_OVERRIDE="$ROOT/.codex-home"
SWIFTPM_CACHE="$ROOT/.swiftpm-cache"
CLANG_MODULE_CACHE="$ROOT/.clang-module-cache"
ICONSET_DIR="$BUILD/AppIcon.iconset"
ICON_SWIFT="$BUILD/generate_icon.swift"
ICON_ICNS="$RES_DIR/AppIcon.icns"
CUSTOM_ICON_TMP="$BUILD/app_folder_icon.png"

APP_BIN_X86="$BUILD/BACK_TO_USSR-x86_64"
APP_BIN_ARM="$BUILD/BACK_TO_USSR-arm64"
SINGBOX_VERSION="1.9.3"
SINGBOX_BASE_URL="https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VERSION}"
SINGBOX_TGZ_X86="$BUILD/sing-box-${SINGBOX_VERSION}-darwin-amd64.tar.gz"
SINGBOX_TGZ_ARM="$BUILD/sing-box-${SINGBOX_VERSION}-darwin-arm64.tar.gz"
SINGBOX_EXTRACT_X86="$BUILD/singbox_extract_amd64"
SINGBOX_EXTRACT_ARM="$BUILD/singbox_extract_arm64"
SINGBOX_BIN_X86="$SINGBOX_EXTRACT_X86/sing-box-${SINGBOX_VERSION}-darwin-amd64/sing-box"
SINGBOX_BIN_ARM="$SINGBOX_EXTRACT_ARM/sing-box-${SINGBOX_VERSION}-darwin-arm64/sing-box"

MUSIC_SRC_DIRS=(
  "$ROOT/assets/music"
  "/Users/danilagulin/Documents/ussr_vpn/music/compress"
)
HERO_IMAGE_CANDIDATES=(
  "$ROOT/assets/subscription_hero.png"
  "$ROOT/docs/media/logo-hero.png"
  "/Users/danilagulin/Documents/ussr_vpn/logo_ussr/image.jpg_attr1-topaz-upscale-4x_attr1_subject1.png"
)

mkdir -p "$BUILD" "$DIST" "$MODULE_CACHE" "$HOME_OVERRIDE" "$SWIFTPM_CACHE" "$CLANG_MODULE_CACHE"
rm -rf "$APP" "$SINGBOX_EXTRACT_X86" "$SINGBOX_EXTRACT_ARM"
mkdir -p "$BIN_DIR" "$RES_DIR"

echo "[1/5] Download sing-box universal slices..."
if [[ ! -f "$SINGBOX_TGZ_X86" ]]; then
  curl -fL "$SINGBOX_BASE_URL/sing-box-${SINGBOX_VERSION}-darwin-amd64.tar.gz" -o "$SINGBOX_TGZ_X86"
else
  echo "Using cached tarball: $SINGBOX_TGZ_X86"
fi

if [[ ! -f "$SINGBOX_TGZ_ARM" ]]; then
  curl -fL "$SINGBOX_BASE_URL/sing-box-${SINGBOX_VERSION}-darwin-arm64.tar.gz" -o "$SINGBOX_TGZ_ARM"
else
  echo "Using cached tarball: $SINGBOX_TGZ_ARM"
fi

mkdir -p "$SINGBOX_EXTRACT_X86" "$SINGBOX_EXTRACT_ARM"
tar -xzf "$SINGBOX_TGZ_X86" -C "$SINGBOX_EXTRACT_X86"
tar -xzf "$SINGBOX_TGZ_ARM" -C "$SINGBOX_EXTRACT_ARM"
if [[ ! -x "$SINGBOX_BIN_X86" || ! -x "$SINGBOX_BIN_ARM" ]]; then
  echo "[ERROR] sing-box binary not found after extraction"
  exit 1
fi
lipo -create "$SINGBOX_BIN_X86" "$SINGBOX_BIN_ARM" -output "$RES_DIR/sing-box"
chmod +x "$RES_DIR/sing-box"

echo "[2/5] Compile BACK_TO_USSR universal..."
SWIFT_MODULECACHE_PATH="$MODULE_CACHE" CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" \
swiftc \
  -target x86_64-apple-macos11.0 \
  -sdk "$SDK" \
  -O \
  "$SRC" \
  "${CORE_SRC[@]}" \
  -o "$APP_BIN_X86"

SWIFT_MODULECACHE_PATH="$MODULE_CACHE" CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" \
swiftc \
  -target arm64-apple-macos11.0 \
  -sdk "$SDK" \
  -O \
  "$SRC" \
  "${CORE_SRC[@]}" \
  -o "$APP_BIN_ARM"

lipo -create "$APP_BIN_X86" "$APP_BIN_ARM" -output "$BIN_DIR/BACK_TO_USSR"

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
makeIcon(64, "icon_64x64.png")
makeIcon(128, "icon_128x128.png")
makeIcon(256, "icon_128x128@2x.png")
makeIcon(256, "icon_256x256.png")
makeIcon(512, "icon_256x256@2x.png")
makeIcon(512, "icon_512x512.png")
makeIcon(1024, "icon_512x512@2x.png")
makeIcon(1024, "icon_1024x1024.png")
SWIFT
HOME="$HOME_OVERRIDE" \
SWIFT_MODULECACHE_PATH="$MODULE_CACHE" \
CLANG_MODULE_CACHE_PATH="$CLANG_MODULE_CACHE" \
swift "$ICON_SWIFT" "$ICONSET_DIR"
python3 "$ROOT/scripts/build_icns.py" "$ICONSET_DIR" "$ICON_ICNS"

TRACK_COUNT=0
for candidate_dir in "${MUSIC_SRC_DIRS[@]}"; do
  if [[ -d "$candidate_dir" ]]; then
    while IFS= read -r -d '' f; do
      name="$(basename "$f")"
      cp "$f" "$RES_DIR/$name"
      TRACK_COUNT=$((TRACK_COUNT + 1))
    done < <(find "$candidate_dir" -maxdepth 1 -type f -name "*.mp3" -print0 | sort -z)
    break
  fi
done
if [[ "$TRACK_COUNT" -gt 0 ]]; then
  echo "Bundled tracks: $TRACK_COUNT"
else
  echo "No music dir found in configured search paths"
fi

for hero_candidate in "${HERO_IMAGE_CANDIDATES[@]}"; do
  if [[ -f "$hero_candidate" ]]; then
    cp "$hero_candidate" "$RES_DIR/subscription_hero.png"
    echo "Bundled subscription hero image"
    break
  fi
done
if [[ ! -f "$RES_DIR/subscription_hero.png" ]]; then
  echo "No hero image found in configured search paths"
fi

if [[ -f "$RES_DIR/subscription_hero.png" ]]; then
  sips -z 512 512 "$RES_DIR/subscription_hero.png" --out "$CUSTOM_ICON_TMP" >/dev/null
  /usr/bin/sips -i "$CUSTOM_ICON_TMP" >/dev/null
  /usr/bin/DeRez -only icns "$CUSTOM_ICON_TMP" > "$BUILD/app_icon.rsrc"
  ICON_FILE="$APP"$'/Icon\r'
  cp "$CUSTOM_ICON_TMP" "$ICON_FILE"
  /usr/bin/Rez -append "$BUILD/app_icon.rsrc" -o "$ICON_FILE"
  /usr/bin/SetFile -a V "$ICON_FILE"
  /usr/bin/SetFile -a C "$APP"
  echo "Applied custom app folder icon from subscription hero"
fi

echo "[5/6] Ad-hoc sign..."
xattr -cr "$APP" || true
codesign --force --deep --sign - "$APP"

file "$BIN_DIR/BACK_TO_USSR"
file "$RES_DIR/sing-box"

echo "[6/6] Package zip + dmg..."
rm -f "$DIST/BACK_TO_USSR.app.zip" "$DIST/BACK_TO_USSR.dmg"
(
  cd "$DIST"
  ditto -c -k --sequesterRsrc --keepParent "BACK_TO_USSR.app" "BACK_TO_USSR.app.zip"
)
hdiutil create -volname "BACK_TO_USSR" -srcfolder "$APP" -ov -format UDZO "$DIST/BACK_TO_USSR.dmg" >/dev/null

ls -lh "$DIST/BACK_TO_USSR.app.zip" "$DIST/BACK_TO_USSR.dmg"
echo "Done: $APP"
