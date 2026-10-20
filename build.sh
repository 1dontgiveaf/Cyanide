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
#   SDK=iphoneos26.2 ARCHS=arm64e IPHONEOS_DEPLOYMENT_TARGET=17.0 ./build.sh
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
export IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-17.0}"

# Settings → What's New and the Home card read Cyanide/Changelog.plist. It is
# not in git (release.sh regenerates it for each release), so a local build
# without it shipped no What's New at all. Generate it from the release tags
# when missing; an existing one (release.sh's pending entry) is kept.
if [ ! -f "$ROOT/Cyanide/Changelog.plist" ]; then
    (cd "$ROOT" && ./scripts/gen-changelog.sh) || echo "==> changelog generation failed (continuing without it)"
fi

exec "$ROOT/scripts/build.sh"
