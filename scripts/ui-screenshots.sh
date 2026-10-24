#!/bin/sh
# Runs UI tests and exports their screenshot attachments as PNGs (shell screencapture lacks Screen Recording permission).
# Usage: scripts/ui-screenshots.sh [-o out-dir] <VeyaUITests/Class[/test]> ...
# Prints one "<attachment name>\t<png path>" line per screenshot. Tests attach via attachScreenshot(of:named:).
set -eu
cd "$(dirname "$0")/.."
out="${TMPDIR:-/tmp}/veya-screenshots"
if [ "${1:-}" = "-o" ]; then out="$2"; shift 2; fi
[ $# -gt 0 ] || { sed -n 3p "$0" >&2; exit 64; }

mkdir -p "$out"
rm -rf "$out/result.xcresult" "$out/png"
only=""
for test in "$@"; do only="$only -only-testing:$test"; done

status=0
# shellcheck disable=SC2086
xcodebuild test -project Veya.xcodeproj -scheme Veya -destination 'platform=macOS' \
    -resultBundlePath "$out/result.xcresult" $only >"$out/xcodebuild.log" 2>&1 || status=$?
[ -d "$out/result.xcresult" ] || { tail -30 "$out/xcodebuild.log" >&2; exit "${status:-1}"; }

xcrun xcresulttool export attachments --path "$out/result.xcresult" --output-path "$out/png" --filter '*.png' >/dev/null
python3 - "$out/png" <<'EOF'
import json, os, re, sys
root = sys.argv[1]
for test in json.load(open(os.path.join(root, "manifest.json"))):
    for a in test["attachments"]:
        name = re.sub(r"_\d+_[0-9A-F-]{36}\.png$", "", a.get("suggestedHumanReadableName", a["exportedFileName"]))
        print(f'{name}\t{os.path.join(root, a["exportedFileName"])}')
EOF
[ "$status" -eq 0 ] || { grep -E "error:|' failed" "$out/xcodebuild.log" | tail -20 >&2; echo "tests failed (log: $out/xcodebuild.log)" >&2; }
exit "$status"
