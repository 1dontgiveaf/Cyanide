#!/usr/bin/env bash
# Synthetic release-note/changelog regression coverage; no build or publish step.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRATCH_ROOT="${RELEASE_TEST_SCRATCH_ROOT:-$ROOT/.work/fix-reports/release-scratch}"
mkdir -p "$SCRATCH_ROOT"
CASE="$(mktemp -d "$SCRATCH_ROOT/notes.XXXXXX")"
trap 'rm -rf "$CASE"' EXIT

bash -n "$ROOT/scripts/release-notes.sh" "$ROOT/scripts/gen-changelog.sh" "$ROOT/scripts/release.sh"
mkdir -p "$CASE/Cyanide" "$CASE/scripts"
cp "$ROOT/scripts/release-notes.sh" "$ROOT/scripts/gen-changelog.sh" "$CASE/scripts/"
chmod +x "$CASE/scripts/gen-changelog.sh"

cat > "$CASE/RELEASE_NOTES.md" <<'EOF'
# Release Notes

## Pending

- [ ] fallback pending bullet

## Released

### v1.9.0 - 2026-10-19

- [x] historical curated bullet
EOF
cat > "$CASE/RELEASE_NOTES_1.10.0.md" <<'EOF'
# Cyanide 1.10.0

## New

- Curated top-level bullet.
  - Curated nested detail.

## Fixes

- Curated fix bullet.
EOF
cat > "$CASE/override.md" <<'EOF'
## Released

### v1.9.0 - 2026-10-19

- [x] explicit override bullet
EOF

(
    cd "$CASE"
    git init -q
    git config user.email test@example.invalid
    git config user.name Test
    touch Cyanide/placeholder
    git add .
    git commit -qm base
    git tag v1.9.0
    printf '%s\n' next > change
    git add change
    git commit -qm 'post release change'

    . ./scripts/release-notes.sh
    test "$(release_notes_file_for_version 1.10.0)" = RELEASE_NOTES_1.10.0.md
    test "$(release_notes_file_for_version 1.11.0)" = RELEASE_NOTES.md
    test "$(release_notes_file_for_version 1.10.0 override.md)" = override.md

    CHANGELOG_PENDING_VERSION=1.10.0 \
    CHANGELOG_PENDING_BASE=v1.9.0 \
        ./scripts/gen-changelog.sh >/dev/null
    grep -Fq '<string>Curated top-level bullet.</string>' Cyanide/Changelog.plist
    grep -Fq '<string>Curated nested detail.</string>' Cyanide/Changelog.plist
    grep -Fq '<string>historical curated bullet</string>' Cyanide/Changelog.plist

    CHANGELOG_RELEASE_NOTES_FILE=override.md ./scripts/gen-changelog.sh >/dev/null
    grep -Fq '<string>explicit override bullet</string>' Cyanide/Changelog.plist
)

grep -Fq 'release_notes_file_for_version "$NEW_VERSION"' "$ROOT/scripts/release.sh"
gngrep='NOTES="${NOTES_ARG:-${NOTES_FROM_FILE:-${NOTES:-$NOTES_DEFAULT}}}"'
grep -Fq "$gngrep" "$ROOT/scripts/release.sh"
printf '%s\n' 'PASS: release-note selection, historical parsing, and explicit override'
