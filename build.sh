#!/usr/bin/env bash
# Build an unsigned arm64e Release IPA without opening Xcode.
#
# Usage:
#   ./build.sh
#
# Result:
#   build/Cyanide-<version>.ipa
#   build/Cyanide.ipa -> Cyanide-<version>.ipa
#
# Optional overrides:
#   SDK=iphoneos26.2 ARCHS=arm64e IPHONEOS_DEPLOYMENT_TARGET=16.0 ./build.sh
#   SCHEME=CyanideVPhone ./build.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"

export SCHEME="${SCHEME:-Cyanide}"
if [ "$SCHEME" = "CyanideVPhone" ]; then
    export CONFIG="${CONFIG:-VPhone Debug}"
else
    export CONFIG="${CONFIG:-Release}"
fi
export SDK="${SDK:-iphoneos}"
export ARCHS="${ARCHS:-arm64e}"
export IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-16.0}"

# scripts/build.sh owns the one missing-resource check so direct CI builds and
# this Release wrapper cannot recurse or generate twice. An existing resource
# (including release.sh's pending entry or a local custom file) is preserved.
exec "$ROOT/scripts/build.sh"
