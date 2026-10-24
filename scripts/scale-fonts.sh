#!/usr/bin/env bash
# Rewrites fixed fonts in Veya/ to the text-size-aware ScaledFont (PBI-801).
# Idempotent: rewritten lines no longer match. macOS text style sizes:
# caption 10, callout 12, body/headline 13, title2 17.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
for f in Veya/*.swift; do
    [[ "$f" == Veya/Theme.swift ]] && continue
    sed -E -i '' \
        -e 's/\.font\(\.system\(size: (.*)\)\)$/.scaledFont(size: \1)/' \
        -e 's/\.font\(Theme\.([A-Za-z]+)\)/.modifier(Theme.\1)/' \
        -e 's/\.font\(\.caption\)/.scaledFont(size: 10)/' \
        -e 's/\.font\(\.callout\)/.scaledFont(size: 12)/' \
        -e 's/\.font\(\.headline\)/.scaledFont(size: 13, weight: .bold)/' \
        -e 's/\.font\(\.title2\)/.scaledFont(size: 17)/' \
        -e 's/\.font\(large \? \.title2 : nil\)/.scaledFont(size: large ? 17 : 13)/' \
        -e 's/\.font\(\.body\.monospaced\(\)\)/.scaledFont(size: 13, design: .monospaced)/' \
        "$f"
done
