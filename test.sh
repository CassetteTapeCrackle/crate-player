#!/usr/bin/env bash
# Runs the CrateCore suite. Command Line Tools ships swift-testing but leaves it off
# the default search paths, and its interop dylib lives in a separate directory, so
# both are supplied here. A bare "swift test" will fail without this.
set -uo pipefail
DEV="/Library/Developer/CommandLineTools/Library/Developer"
export DYLD_LIBRARY_PATH="$DEV/usr/lib${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
export DYLD_FRAMEWORK_PATH="$DEV/Frameworks${DYLD_FRAMEWORK_PATH:+:$DYLD_FRAMEWORK_PATH}"
exec swift test \
  -Xswiftc -F -Xswiftc "$DEV/Frameworks" \
  -Xlinker -rpath -Xlinker "$DEV/Frameworks" \
  -Xlinker -rpath -Xlinker "$DEV/usr/lib" "$@"
