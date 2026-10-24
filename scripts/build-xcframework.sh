#!/usr/bin/env bash
# Builds spotcore (release: both macOS arches lipo'd into a universal static
# library; debug: host arch only), wraps it in SpotCoreKit/spotcoreFFI.xcframework and regenerates
# the UniFFI Swift bindings into SpotCoreKit/Sources/SpotCoreKit.
#
# Usage: scripts/build-xcframework.sh [debug|release]   (default: release)
# From Xcode the profile follows $CONFIGURATION (Debug -> debug).
#
# Skips all work when core/, this script and the profile are unchanged since
# the last successful run (stamp file). Outputs are swapped in only after
# every step succeeds, so a crashed run leaves the previous outputs and no
# stamp, and the next run rebuilds. A failed run replaces the bindings with an
# #error stub so Xcode reports the Rust failure instead of stale-API errors.
# Concurrent runs (terminal, scheme pre-action, build phase) are serialized.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE="$ROOT/core"
PKG="$ROOT/SpotCoreKit"
XCFRAMEWORK="$PKG/spotcoreFFI.xcframework"
SWIFT_OUT="$PKG/Sources/SpotCoreKit/spotcore.swift"

if [[ $# -gt 0 ]]; then
    PROFILE="$1"
elif [[ "${CONFIGURATION:-}" == "Debug" ]]; then
    PROFILE=debug
else
    PROFILE=release
fi
case "$PROFILE" in
    debug) CARGO_PROFILE=dev ;;
    release) CARGO_PROFILE=release ;;
    *) echo "error: profile must be debug or release, got '$PROFILE'" >&2; exit 64 ;;
esac

# Debug runs only need the arch being built (Xcode Debug sets ONLY_ACTIVE_ARCH).
host_target() {
    local arch="${NATIVE_ARCH:-$(uname -m)}"
    case "$arch" in
        arm64*) echo aarch64-apple-darwin ;;
        x86_64) echo x86_64-apple-darwin ;;
        *) echo "error: unsupported host arch '$arch'" >&2; exit 64 ;;
    esac
}
if [[ "$PROFILE" == debug ]]; then
    TARGETS=("$(host_target)")
else
    TARGETS=(aarch64-apple-darwin x86_64-apple-darwin)
fi

# Honor xcode-select; the Command Line Tools alone lack xcodebuild.
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
    DEVELOPER_DIR="$(xcode-select -p)"
    if [[ "$DEVELOPER_DIR" == */CommandLineTools ]]; then
        DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
    fi
fi

# Xcode exports settings like SDKROOT=auto that break cc-rs, and any env
# difference between callers (scheme pre-action, build phase, terminal)
# invalidates cargo build-script caches. Every tool runs in this fixed env.
# MACOSX_DEPLOYMENT_TARGET matches the app minimum so ld does not warn.
# PATH is fixed rather than inherited (Xcode's differs from a shell's) and
# covers rustup from rustup.rs, $CARGO_HOME and Homebrew.
CARGO_BIN="${CARGO_HOME:-$HOME/.cargo}/bin"
CLEAN_PATH="$CARGO_BIN:/opt/homebrew/opt/rustup/bin:/opt/homebrew/bin"
CLEAN_PATH+=":/usr/local/opt/rustup/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
RUST_HOMES=()
[[ -n "${CARGO_HOME:-}" ]] && RUST_HOMES+=(CARGO_HOME="$CARGO_HOME")
[[ -n "${RUSTUP_HOME:-}" ]] && RUST_HOMES+=(RUSTUP_HOME="$RUSTUP_HOME")
clean_env() {
    env -i \
        HOME="$HOME" \
        USER="${USER:-}" \
        TMPDIR="${TMPDIR:-/tmp}" \
        PATH="$CLEAN_PATH" \
        ${RUST_HOMES[@]+"${RUST_HOMES[@]}"} \
        DEVELOPER_DIR="$DEVELOPER_DIR" \
        MACOSX_DEPLOYMENT_TARGET=14.0 \
        "$@"
}

mkdir -p "$CORE/target"
LOCK="$CORE/target/.xcframework.lock"
# shlock records our pid and breaks locks whose owner has died.
until shlock -f "$LOCK" -p $$; do
    sleep 1
done

write_error_stub() {
    mkdir -p "$(dirname "$SWIFT_OUT")"
    printf '#error("spotcore Rust build failed; run scripts/build-xcframework.sh %s (Xcode log: core/target/xcframework-preaction.log)")\n' \
        "$PROFILE" > "$SWIFT_OUT"
}
on_exit() {
    local status=$?
    if [[ $status -ne 0 ]]; then
        write_error_stub
    fi
    rm -f "$LOCK"
    exit $status
}
trap on_exit EXIT

if ! clean_env sh -c 'command -v cargo' >/dev/null; then
    echo "error: cargo not found in $CLEAN_PATH; install rustup or set CARGO_HOME" >&2
    exit 69
fi

# One stamp for both profiles: they share the outputs, and the fingerprint
# includes the profile, so switching profiles rebuilds.
STAMP="$CORE/target/.xcframework.stamp"
fingerprint() {
    {
        echo "$PROFILE ${TARGETS[*]}"
        shasum < "${BASH_SOURCE[0]}"
        find "$CORE" -type d -name target -prune -o -type f -print0 \
            | LC_ALL=C sort -z | xargs -0 shasum
    } | shasum | cut -d' ' -f1
}
FINGERPRINT="$(fingerprint)"
if [[ -f "$STAMP" && "$(cat "$STAMP")" == "$FINGERPRINT" \
      && -d "$XCFRAMEWORK" && -f "$SWIFT_OUT" ]]; then
    echo "spotcore unchanged, skipping Rust build"
    exit 0
fi
rm -f "$STAMP"

# rustup resolves core/rust-toolchain.toml from the cwd, and bindgen's
# `cargo metadata` needs the workspace as cwd.
cd "$CORE"
# CI must build the shipped library from exactly the committed Cargo.lock.
LOCKED=()
[[ -n "${CI:-}" ]] && LOCKED=(--locked)
for target in "${TARGETS[@]}"; do
    clean_env cargo build ${LOCKED[@]+"${LOCKED[@]}"} -p spotcore \
        --target "$target" --profile "$CARGO_PROFILE"
done

STAGING="$CORE/target/xcframework-staging"
rm -rf "$STAGING"
mkdir -p "$(dirname "$SWIFT_OUT")"
mkdir -p "$STAGING/headers/spotcoreFFI" "$STAGING/swift"

SLICES=()
for target in "${TARGETS[@]}"; do
    SLICES+=("$CORE/target/$target/$PROFILE/libspotcore.a")
done
clean_env lipo -create -output "$STAGING/libspotcore.a" "${SLICES[@]}"

clean_env cargo run ${LOCKED[@]+"${LOCKED[@]}"} --quiet -p uniffi-bindgen -- \
    generate --library "$CORE/target/${TARGETS[0]}/$PROFILE/libspotcore.a" \
    --language swift --out-dir "$STAGING/swift"

# Nested header dir keeps this module.modulemap from colliding with other
# xcframeworks that also ship one at the Headers root.
cp "$STAGING/swift/spotcoreFFI.h" "$STAGING/headers/spotcoreFFI/"
cp "$CORE/spotcore/include/spotcore_audio.h" "$STAGING/headers/spotcoreFFI/"
# The real-time audio C API (ADR-006) is not UniFFI's, so add its header to the module.
sed 's|^\( *\)header "spotcoreFFI.h"|&\
\1header "spotcore_audio.h"|' "$STAGING/swift/spotcoreFFI.modulemap" \
    > "$STAGING/headers/spotcoreFFI/module.modulemap"
grep -q 'header "spotcore_audio.h"' "$STAGING/headers/spotcoreFFI/module.modulemap"

clean_env xcodebuild -create-xcframework \
    -library "$STAGING/libspotcore.a" \
    -headers "$STAGING/headers" \
    -output "$STAGING/spotcoreFFI.xcframework" >/dev/null

rm -rf "$XCFRAMEWORK"
mv "$STAGING/spotcoreFFI.xcframework" "$XCFRAMEWORK"
# Unchanged bindings keep their mtime so Xcode does not recompile SpotCoreKit.
if ! cmp -s "$STAGING/swift/spotcore.swift" "$SWIFT_OUT"; then
    mv "$STAGING/swift/spotcore.swift" "$SWIFT_OUT"
fi
rm -rf "$STAGING"
echo "$FINGERPRINT" > "$STAMP"
echo "built $XCFRAMEWORK ($PROFILE)"
