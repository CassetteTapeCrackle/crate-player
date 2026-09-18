#!/usr/bin/env bash
# Compiles Crate and assembles a macOS app bundle. Xcode is not installed and is not
# needed: swiftc plus a hand-written Info.plist does the whole job.
set -euo pipefail
cd "$(dirname "$0")"

INSTALL=0
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=1 ;;
    -h|--help)
      echo "usage: ./build.sh [--install]"
      echo "  --install   after building, replace /Applications/Crate.app"
      exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

# The release script passes the version through so the bundle stops claiming 1.0.
VERSION="${CRATE_VERSION:-1.0}"

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
  -swift-version 6 \
  -module-name CrateCore \
  -emit-module -emit-module-path "$MODULES/CrateCore.swiftmodule" \
  -emit-library -static -o "$MODULES/libCrateCore.a" \
  $(find Sources/CrateCore -name '*.swift')

echo "Compiling CrateApp..."
swiftc -O \
  -target arm64-apple-macos14.0 \
  -swift-version 6 \
  -parse-as-library \
  -I "$MODULES" -L "$MODULES" -lCrateCore \
  $(find Sources/CrateApp -name '*.swift') \
  -o "$APP/Contents/MacOS/Crate"

cp Resources/DepartureMono-Regular.otf "$APP/Contents/Resources/Fonts/"
cp Resources/Crate.icns "$APP/Contents/Resources/"
cp Resources/menubar.png "$APP/Contents/Resources/"
cp Resources/DepartureMono-LICENSE.txt "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>Crate</string>
  <key>CFBundleIdentifier</key><string>local.crate.player</string>
  <key>CFBundleName</key><string>Crate</string>
  <key>CFBundleDisplayName</key><string>Crate</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>ATSApplicationFontsPath</key><string>Fonts</string>
  <key>CFBundleIconFile</key><string>Crate</string>
</dict></plist>
PLIST

# Ad-hoc signature. Because the bundle is built here rather than downloaded, it
# carries no com.apple.quarantine attribute and Gatekeeper never challenges it.
codesign --force --deep --sign - "$APP" 2>/dev/null

echo "Built $APP"

if [ "$INSTALL" -eq 1 ]; then
  DEST="/Applications/Crate.app"
  BUNDLE_ID=$(plutil -extract CFBundleIdentifier raw "$APP/Contents/Info.plist")

  # Never delete something in /Applications that is not this app. If anything
  # else is sitting at that path, stop and let a human decide.
  if [ -e "$DEST" ]; then
    EXISTING=$(plutil -extract CFBundleIdentifier raw "$DEST/Contents/Info.plist" 2>/dev/null || echo "")
    if [ "$EXISTING" != "$BUNDLE_ID" ]; then
      echo "Refusing to replace $DEST" >&2
      echo "  expected identifier $BUNDLE_ID, found '${EXISTING:-none}'" >&2
      exit 1
    fi
  fi

  # A running copy holds its binary open, so quit it before overwriting and put
  # it back afterwards if it was up.
  WAS_RUNNING=0
  if pgrep -f "$DEST/Contents/MacOS/Crate" >/dev/null 2>&1; then
    WAS_RUNNING=1
    osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5 6; do
      pgrep -f "$DEST/Contents/MacOS/Crate" >/dev/null 2>&1 || break
      sleep 0.5
    done
    pkill -f "$DEST/Contents/MacOS/Crate" >/dev/null 2>&1 || true
  fi

  rm -rf "$DEST"
  cp -R "$APP" "$DEST"
  echo "Installed $DEST"

  if [ "$WAS_RUNNING" -eq 1 ]; then
    open "$DEST"
    echo "Relaunched"
  fi
fi
