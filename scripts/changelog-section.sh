#!/bin/sh
# Prints the CHANGELOG.md entry for a version ("## [1.2.0] - 2026-10-14" up to the next "## ").
# Fails when the entry is missing or empty, so a tag cannot ship without release notes.
# Usage: scripts/changelog-section.sh <version> [changelog]
set -eu
version="$1"
changelog="${2:-$(dirname "$0")/../CHANGELOG.md}"
notes=$(awk -v v="$version" '
    /^## / { if (found) exit; found = index($0, "## [" v "]") == 1; next }
    found' "$changelog" | sed '/./,$!d')
if [ -z "$(printf %s "$notes" | tr -d '[:space:]')" ]; then
    echo "error: $changelog has no entry for $version" >&2
    exit 1
fi
printf '%s\n' "$notes"
