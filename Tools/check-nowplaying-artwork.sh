#!/usr/bin/env bash
# Compiles and runs the Now Playing artwork regression test against the real
# NowPlayingBridge source. Traps show up as a non-zero exit.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="build/checks"
mkdir -p "$OUT"

swiftc -O -target arm64-apple-macos14.0 -swift-version 6 \
  -module-name CrateCore -emit-module -emit-module-path "$OUT/CrateCore.swiftmodule" \
  -emit-library -static -o "$OUT/libCrateCore.a" \
  $(find Sources/CrateCore -name '*.swift')

# Top-level code is only allowed in a file called main.swift, so stage it as one.
cp Tools/check-nowplaying-artwork.swift "$OUT/main.swift"

swiftc -O -target arm64-apple-macos14.0 -swift-version 6 \
  -I "$OUT" -L "$OUT" -lCrateCore \
  Sources/CrateApp/NowPlayingBridge.swift \
  "$OUT/main.swift" \
  -o "$OUT/check-nowplaying-artwork"

"$OUT/check-nowplaying-artwork"
