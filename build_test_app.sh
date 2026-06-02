#!/bin/bash
# Builds PhotoOrienterTest.app — identical to PhotoOrienter.app but uses the
# test-weight engine (scene > body > face > horizon). Both apps can run
# side-by-side for direct comparison against the same image folder.
set -euo pipefail

cd "$(dirname "$0")"
ROOT="$(pwd)"
APP="PhotoOrienterTest.app"
APP_NAME="Photo Orienter Test"
BUNDLE_ID="io.github.ef-net.bulk-photo-orienter-test"

echo "▶︎ Building test engine (correct_orientation_test)…"
swiftc correct_orientation_test.swift -O \
    -o correct_orientation_test \
    -framework Vision -framework ImageIO -framework AppKit

echo "▶︎ Compiling GUI…"
swiftc gui/PhotoOrienterApp.swift -O -parse-as-library \
    -o /tmp/PhotoOrienterTest.bin \
    -framework SwiftUI -framework AppKit -framework UniformTypeIdentifiers \
    -target arm64-apple-macos14.0

echo "▶︎ Assembling $APP…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

mv /tmp/PhotoOrienterTest.bin "$APP/Contents/MacOS/PhotoOrienter"
chmod +x "$APP/Contents/MacOS/PhotoOrienter"

# Embed the TEST engine binary so the app is self-contained.
cp correct_orientation_test "$APP/Contents/Resources/correct_orientation"
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

codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || \
    echo "  (codesign skipped — app will still run locally)"

echo "✓ Built $ROOT/$APP"
echo "  Launch with:  open \"$ROOT/$APP\""
echo "  Weights: scene 3.0 · body 2.5 · face 2.0 · horizon 0.5"
