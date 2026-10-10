#!/bin/bash
# Run isolated tests without starting Tendedero or changing screenshot settings.
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$PWD/.build/ModuleCache}"

# The CLT-only macOS 27 SDK lacks the SwiftUI plugin (see build-app.sh).
if [ -z "${SDKROOT:-}" ] && [ "$(xcode-select -p)" = "/Library/Developer/CommandLineTools" ]; then
  FALLBACK="$(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX26*.sdk 2>/dev/null | sort -V | tail -1 || true)"
  if [ -n "$FALLBACK" ]; then export SDKROOT="$FALLBACK"; fi
fi

# Some CLT releases ship Swift Testing without XCTest and do not load the
# bundled Testing macro automatically. No external dependency is needed.
ARGS=(--disable-xctest)
PLUGIN="$(dirname "$(xcrun --find swiftc)")/../lib/swift/host/plugins/testing/libTestingMacros.dylib"
if [ -f "$PLUGIN" ]; then
  ARGS+=(-Xswiftc -load-plugin-library -Xswiftc "$PLUGIN")
fi
swift test --disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security "${ARGS[@]}" "$@"
