#!/bin/bash
# Builds PhotoOrienter.app — a native macOS front end for the orientation
# engine. Uses only the Swift toolchain bundled with macOS Command Line
# Tools; no Xcode project, CocoaPods, or other dependencies required.
set -euo pipefail

cd "$(dirname "$0")"
ROOT="$(pwd)"
APP="PhotoOrienter.app"
APP_NAME="Photo Orienter"
BUNDLE_ID="io.github.ef-net.bulk-photo-orienter"

echo "▶︎ Building engine (correct_orientation)…"
swiftc correct_orientation.swift -O \
    -o correct_orientation \
    -framework Vision -framework ImageIO -framework AppKit

echo "▶︎ Compiling GUI…"
swiftc gui/PhotoOrienterApp.swift -O -parse-as-library \
    -o /tmp/PhotoOrienter.bin \
    -framework SwiftUI -framework AppKit -framework UniformTypeIdentifiers \
    -target arm64-apple-macos14.0

echo "▶︎ Assembling $APP…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

mv /tmp/PhotoOrienter.bin "$APP/Contents/MacOS/PhotoOrienter"
chmod +x "$APP/Contents/MacOS/PhotoOrienter"

# Embed the engine binary so the app is fully self-contained.
cp correct_orientation "$APP/Contents/Resources/correct_orientation"
chmod +x "$APP/Contents/Resources/correct_orientation"

echo "▶︎ Generating app icon…"
swiftc gui/make_icon.swift -O -o /tmp/make_icon -framework AppKit
/tmp/make_icon /tmp/icon_master.png
ICONSET="/tmp/AppIcon.iconset"
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
    sips -z $s $s        /tmp/icon_master.png --out "$ICONSET/icon_${s}x${s}.png"      >/dev/null
    sips -z $((s*2)) $((s*2)) /tmp/icon_master.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET" /tmp/icon_master.png

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key><string>1.0</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleExecutable</key><string>PhotoOrienter</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIconName</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

# Ad-hoc code signature so Gatekeeper lets it launch locally.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || \
    echo "  (codesign skipped — app will still run locally)"

# Package the bundle into the zip that the README links for download.
echo "▶︎ Zipping $APP → $APP.zip…"
rm -f "$APP.zip"
ditto -c -k --keepParent "$APP" "$APP.zip"

echo "✓ Built $ROOT/$APP"
echo "  Launch with:  open \"$ROOT/$APP\""
echo "  Download zip: $ROOT/$APP.zip ($(du -h "$APP.zip" | cut -f1))"
