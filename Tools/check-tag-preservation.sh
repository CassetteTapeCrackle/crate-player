#!/usr/bin/env bash
# Compiles and runs the tag preservation guard against the real CrateCore writer.
# Failures exit non-zero.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="build/checks-tagging"
mkdir -p "$OUT"

swiftc -O -target arm64-apple-macos14.0 -swift-version 6 \
  -module-name CrateCore -emit-module -emit-module-path "$OUT/CrateCore.swiftmodule" \
  -emit-library -static -o "$OUT/libCrateCore.a" \
  $(find Sources/CrateCore -name '*.swift')

# Top-level code is only allowed in a file called main.swift, so stage it as one.
cp Tools/check-tag-preservation.swift "$OUT/main.swift"

swiftc -O -target arm64-apple-macos14.0 -swift-version 6 \
  -I "$OUT" -L "$OUT" -lCrateCore \
  "$OUT/main.swift" \
  -o "$OUT/check-tag-preservation"

"$OUT/check-tag-preservation"
