#!/usr/bin/env bash
# Runs the CrateCore suite.
#
# Command Line Tools ships swift-testing but leaves it off the default search
# paths, and keeps its interop dylib in a separate directory, so those have to be
# supplied by hand. A full Xcode install (and every GitHub macOS runner) already
# resolves them, so fall through to a plain invocation there.
set -uo pipefail
DEV="/Library/Developer/CommandLineTools/Library/Developer"

if [ -d "$DEV/Frameworks/Testing.framework" ] && [ -f "$DEV/usr/lib/lib_TestingInterop.dylib" ]; then
  export DYLD_LIBRARY_PATH="$DEV/usr/lib${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
  export DYLD_FRAMEWORK_PATH="$DEV/Frameworks${DYLD_FRAMEWORK_PATH:+:$DYLD_FRAMEWORK_PATH}"
  exec swift test \
    -Xswiftc -F -Xswiftc "$DEV/Frameworks" \
    -Xlinker -rpath -Xlinker "$DEV/Frameworks" \
    -Xlinker -rpath -Xlinker "$DEV/usr/lib" "$@"
fi

exec swift test "$@"
