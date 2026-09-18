#!/usr/bin/env bash
# Compiles Crate and assembles a macOS app bundle. Xcode is not installed and is not
# needed: swiftc plus a hand-written Info.plist does the whole job.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Crate.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Fonts"

MODULES="build/modules"
mkdir -p "$MODULES"

# CrateCore is built as a real module so the logic/UI boundary the tests rely on
# also holds in the shipped binary.
echo "Compiling CrateCore..."
swiftc -O \
  -target arm64-apple-macos14.0 \
  -module-name CrateCore \
  -emit-module -emit-module-path "$MODULES/CrateCore.swiftmodule" \
  -emit-library -static -o "$MODULES/libCrateCore.a" \
  $(find Sources/CrateCore -name '*.swift')

echo "Compiling CrateApp..."
swiftc -O \
  -target arm64-apple-macos14.0 \
  -parse-as-library \
  -I "$MODULES" -L "$MODULES" -lCrateCore \
  $(find Sources/CrateApp -name '*.swift') \
  -o "$APP/Contents/MacOS/Crate"

cp Resources/DepartureMono-Regular.otf "$APP/Contents/Resources/Fonts/"
cp Resources/DepartureMono-LICENSE.txt "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>Crate</string>
  <key>CFBundleIdentifier</key><string>local.crate.player</string>
  <key>CFBundleName</key><string>Crate</string>
  <key>CFBundleDisplayName</key><string>Crate</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>ATSApplicationFontsPath</key><string>Fonts</string>
</dict></plist>
PLIST

# Ad-hoc signature. Because the bundle is built here rather than downloaded, it
# carries no com.apple.quarantine attribute and Gatekeeper never challenges it.
codesign --force --deep --sign - "$APP" 2>/dev/null

echo "Built $APP"
