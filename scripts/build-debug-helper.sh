#!/bin/bash
# Build the Debug-only nested-helper proof binary (scripts/debug-helper/hello.c)
# as an arm64/arm64e iOS Mach-O and ad-hoc sign it. The resulting binary is
# copied to Cyanide.app/Helpers/hello when packaging the Debug proof IPA.
#
# The app's signing service must re-sign nested binaries for this test to be
# meaningful; an ad-hoc helper may be rejected by AMFI on a stock device.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/build/debug-helper/hello}"
mkdir -p "$(dirname "$OUT")"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
xcrun --sdk iphoneos clang \
    -arch arm64 -arch arm64e \
    -miphoneos-version-min=17.0 \
    -isysroot "$SDK" -O2 \
    "$ROOT/scripts/debug-helper/hello.c" -o "$OUT"
ldid -S "$OUT"
chmod 0755 "$OUT"
file "$OUT"
