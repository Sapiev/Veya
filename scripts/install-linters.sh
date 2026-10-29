#!/usr/bin/env bash
# Installs the pinned SwiftLint and SwiftFormat release binaries into
# .tools/bin (or $1). CI and local runs use the same versions, so a new
# upstream rule cannot fail strict lint on unchanged code.
#
# It also points git at .githooks, whose pre-commit hook formats and lints
# staged files with them.
#
# Usage: scripts/install-linters.sh [bin-dir]
# Bump a version by updating its URL and sha256 together.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${1:-$ROOT/.tools/bin}"

SWIFTLINT_VERSION=0.65.1
SWIFTLINT_URL="https://github.com/realm/SwiftLint/releases/download/$SWIFTLINT_VERSION/portable_swiftlint.zip"
SWIFTLINT_SHA256=c1e429b0599cf1b516f369a2d9ec04eaf0e436f3c12b637df8851fa52ff694d0

SWIFTFORMAT_VERSION=0.63.1
SWIFTFORMAT_URL="https://github.com/nicklockwood/SwiftFormat/releases/download/$SWIFTFORMAT_VERSION/swiftformat.zip"
SWIFTFORMAT_SHA256=385ef1a263ba28685157b98c5536b9c9105e124518f28b7ef8a2bee4b167eaeb

TMP_DIRS=()
trap 'rm -rf ${TMP_DIRS[@]+"${TMP_DIRS[@]}"}' EXIT

# Downloads to a temp dir and moves the binary in last, so a crashed run
# never leaves a partial or unverified binary in $BIN.
install_tool() {
    local name="$1" version="$2" url="$3" sha256="$4"
    if [[ -x "$BIN/$name" && "$("$BIN/$name" --version)" == "$version" ]]; then
        return
    fi
    local tmp
    tmp="$(mktemp -d)"
    TMP_DIRS+=("$tmp")
    curl -sSfL --retry 3 -o "$tmp/$name.zip" "$url"
    echo "$sha256  $tmp/$name.zip" | shasum -a 256 -c - >/dev/null
    unzip -q "$tmp/$name.zip" "$name" -d "$tmp"
    mkdir -p "$BIN"
    mv "$tmp/$name" "$BIN/$name"
    echo "installed $name $version"
}

install_tool swiftlint "$SWIFTLINT_VERSION" "$SWIFTLINT_URL" "$SWIFTLINT_SHA256"
install_tool swiftformat "$SWIFTFORMAT_VERSION" "$SWIFTFORMAT_URL" "$SWIFTFORMAT_SHA256"

git -C "$ROOT" config core.hooksPath .githooks 2>/dev/null || true
