#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
SCRIPT_DIR="$ROOT/tests/review-archive-integrity"
SDK=$(xcrun --sdk macosx --show-sdk-path)
BUILD_DIR=$(mktemp -d "${TMPDIR:-/tmp}/cyanide-archive-build.XXXXXX")
trap 'rm -rf "$BUILD_DIR"' EXIT INT TERM

xcrun --sdk macosx clang -fobjc-arc -isysroot "$SDK" \
  -I "$ROOT/Cyanide" \
  -framework Foundation -framework ImageIO \
  "$ROOT/Cyanide/SBLArchiveExtractor.m" \
  "$SCRIPT_DIR/ArchiveIntegrityTests.m" \
  -lz -ldl -o "$BUILD_DIR/archive-integrity-tests"

"$BUILD_DIR/archive-integrity-tests"
