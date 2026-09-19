#!/usr/bin/env bash
# Runs the tag writer over copies of real tracks from a music library and checks that
# only the edited frames moved. Originals are never touched: every file is copied to a
# temporary directory first.
#
# Not run by CI, which has no library. Usage:
#   ./Tools/verify-against-library.sh ["/path/to/library"] [per-format count]
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="build/checks-library"
mkdir -p "$OUT"

swiftc -O -target arm64-apple-macos14.0 -swift-version 6 -enable-testing \
  -module-name CrateCore -emit-module -emit-module-path "$OUT/CrateCore.swiftmodule" \
  -emit-library -static -o "$OUT/libCrateCore.a" \
  $(find Sources/CrateCore -name '*.swift')

cp Tools/verify-against-library.swift "$OUT/main.swift"

swiftc -O -target arm64-apple-macos14.0 -swift-version 6 -enable-testing \
  -I "$OUT" -L "$OUT" -lCrateCore \
  "$OUT/main.swift" \
  -o "$OUT/verify-against-library"

"$OUT/verify-against-library" "$@"
