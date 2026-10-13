#!/bin/sh
# Fails when a String Catalog string lacks a reviewed translation in a shipped language.
# Usage: scripts/check-localizations.sh [catalog ...] (defaults to every catalog in Veya/)
set -eu
cd "$(dirname "$0")/.."
[ $# -gt 0 ] || set -- Veya/*.xcstrings
exec python3 - "$@" <<'EOF'
import json, sys

SHIPPED = ["pl"]

def units(localization):
    """Every stringUnit under a localization, including plural and device variations and substitutions."""
    if "stringUnit" in localization:
        yield localization["stringUnit"]
    for variation in localization.get("variations", {}).values():
        for case in variation.values():
            yield from units(case)
    for substitution in localization.get("substitutions", {}).values():
        yield from units(substitution)

problems = []
for path in sys.argv[1:]:
    for key, entry in json.load(open(path))["strings"].items():
        if entry.get("shouldTranslate") is False:
            continue
        if entry.get("extractionState") == "stale":
            problems.append(f"{path}: stale key {key!r}; delete it")
            continue
        for language in SHIPPED:
            localization = entry.get("localizations", {}).get(language)
            found = list(units(localization)) if localization else []
            if not found or any(unit.get("state") != "translated" for unit in found):
                problems.append(f"{path}: {key!r} has no reviewed {language} translation")

print("\n".join(problems) or "All strings translated.")
sys.exit(1 if problems else 0)
EOF
