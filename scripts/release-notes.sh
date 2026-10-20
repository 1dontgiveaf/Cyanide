#!/usr/bin/env bash
# Shared release-note selection/parsing for release.sh and gen-changelog.sh.
# This file is sourced after callers change to the repository root.

release_notes_file_for_version() {
    local version="$1"
    local override="${2:-}"
    local candidate="RELEASE_NOTES_${version}.md"

    if [ -n "$override" ]; then
        printf '%s\n' "$override"
    elif [ -f "$candidate" ]; then
        printf '%s\n' "$candidate"
    else
        printf '%s\n' "RELEASE_NOTES.md"
    fi
}

release_notes_bullets_for_version() {
    local version="$1"
    local notes_file="$2"
    [ -f "$notes_file" ] || return 0

    # Historical RELEASE_NOTES.md entries use checked bullets under a version
    # heading. Keep that format (and its heading boundaries) unchanged.
    if grep -Eq "^###[[:space:]]+v${version}([[:space:]]|$)" "$notes_file"; then
        awk -v wanted="v${version}" '
            /^###[[:space:]]+/ {
                if (in_version) exit
                heading = $0
                sub(/^###[[:space:]]+/, "", heading)
                split(heading, parts, /[[:space:]]+/)
                if (parts[1] == wanted) in_version = 1
                next
            }
            in_version && /^##[[:space:]]+/ { exit }
            in_version { print }
        ' "$notes_file" \
            | sed -nE 's/^[[:space:]]*-[[:space:]]+\[[xX]\][[:space:]]+(.+[^[:space:]])[[:space:]]*$/\1/p'
        return 0
    fi

    # A versioned draft is a normal Markdown document (## New, ## Fixes, ...),
    # so include its top-level and nested list items without requiring [x].
    if [ "$(basename "$notes_file")" = "RELEASE_NOTES_${version}.md" ]; then
        sed -nE 's/^[[:space:]]*-[[:space:]]+(\[[xX ]\][[:space:]]+)?(.+[^[:space:]])[[:space:]]*$/\2/p' "$notes_file"
        return 0
    fi

    # Pending notes retain the established unchecked-checkbox format.
    awk '
        /^##[[:space:]]+Pending[[:space:]]*$/ { pending = 1; next }
        pending && /^##[[:space:]]+/ { exit }
        pending { print }
    ' "$notes_file" \
        | sed -nE 's/^[[:space:]]*-[[:space:]]+\[[[:space:]]\][[:space:]]+(.+[^[:space:]])[[:space:]]*$/\1/p'
}
