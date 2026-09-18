#!/usr/bin/env bash
# Builds the release artefacts for a given version: a .pkg installer and a .zip of
# the app bundle. Needs only the Command Line Tools; pkgbuild and productbuild
# ship with them.
#
#   ./Tools/make-release.sh 1.0.0
#
# Neither artefact is notarised, because that needs a paid Developer ID. Both will
# therefore arrive quarantined; the README explains how to clear it.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
  echo "usage: ./Tools/make-release.sh <version>   e.g. 1.0.0" >&2
  exit 2
fi

APP="build/Crate.app"
OUT="build/release"
WORK="build/release/work"
IDENTIFIER="local.crate.player"

./build.sh
rm -rf "$OUT"
mkdir -p "$WORK/resources"

# ---- zip: ditto keeps the bundle's metadata and signature intact, plain zip does not
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/Crate-$VERSION.zip"

# ---- pkg
pkgbuild \
  --component "$APP" \
  --install-location /Applications \
  --identifier "$IDENTIFIER" \
  --version "$VERSION" \
  "$WORK/Crate-component.pkg" >/dev/null

cp LICENSE "$WORK/resources/LICENSE.txt"
cat > "$WORK/resources/welcome.html" <<'HTML'
<html><body style="font-family:-apple-system,sans-serif;font-size:13px;line-height:1.5">
<p>This installs <b>Crate</b> into your Applications folder.</p>
<p>Crate plays your music folders in Finder order. Open it, click the gear in the
sidebar, and point it at the directory your music lives in.</p>
<p>It reads your files where they are. It does not copy, move, rename or modify
anything, and it makes no network connections.</p>
</body></html>
HTML

cat > "$WORK/distribution.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>Crate $VERSION</title>
    <organization>local.crate</organization>
    <options customize="never" require-scripts="false" hostArchitectures="arm64"/>
    <domains enable_anywhere="false" enable_currentUserHome="false" enable_localSystem="true"/>
    <welcome file="welcome.html" mime-type="text/html"/>
    <license file="LICENSE.txt" mime-type="text/plain"/>
    <volume-check>
        <allowed-os-versions><os-version min="14.0"/></allowed-os-versions>
    </volume-check>
    <choices-outline>
        <line choice="default"><line choice="$IDENTIFIER"/></line>
    </choices-outline>
    <choice id="default"/>
    <choice id="$IDENTIFIER" visible="false"><pkg-ref id="$IDENTIFIER"/></choice>
    <pkg-ref id="$IDENTIFIER" version="$VERSION" onConclusion="none">Crate-component.pkg</pkg-ref>
</installer-gui-script>
XML

productbuild \
  --distribution "$WORK/distribution.xml" \
  --resources "$WORK/resources" \
  --package-path "$WORK" \
  "$OUT/Crate-$VERSION.pkg" >/dev/null

# ---- verify rather than assume
installer -pkg "$OUT/Crate-$VERSION.pkg" -target / -showChoiceChangesXML >/dev/null
rm -rf "$WORK/check" && mkdir -p "$WORK/check"
ditto -x -k "$OUT/Crate-$VERSION.zip" "$WORK/check"
codesign --verify --strict "$WORK/check/Crate.app"

rm -rf "$WORK"
echo
echo "Release artefacts for $VERSION:"
for f in "$OUT"/*; do
  printf "  %-24s %8s bytes\n" "$(basename "$f")" "$(stat -f%z "$f")"
done
