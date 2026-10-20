#!/usr/bin/env bash
# PBI-X02: link libspotcore.a into a plain SwiftPM executable via a
# systemLibrary target and call one sync, one async and one foreign-callback (LogSink) UniFFI function.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CORE="$ROOT/core"
OUT="${1:-$(mktemp -d)}"
LIBDIR="$CORE/target/release"
LIB="$LIBDIR/libspotcore.a"
case "$(uname)" in MINGW*|MSYS*) WIN=1; LIB="$LIBDIR/spotcore.lib"; LIBDIR="$(cygpath -m "$LIBDIR")";; esac

(cd "$CORE" && cargo build --release -p spotcore)
(cd "$CORE" && cargo run --quiet -p uniffi-bindgen -- generate \
    --library "$LIB" --language swift --out-dir "$OUT/gen")

FFI="$OUT/Sources/spotcoreFFI"
mkdir -p "$FFI" "$OUT/Sources/smoke"
cp "$OUT/gen/spotcoreFFI.h" "$CORE/spotcore/include/spotcore_audio.h" "$FFI/"
sed 's|^\( *\)header "spotcoreFFI.h"|&\
\1header "spotcore_audio.h"|' "$OUT/gen/spotcoreFFI.modulemap" > "$FFI/module.modulemap"
cp "$OUT/gen/spotcore.swift" "$OUT/Sources/smoke/"
cat > "$OUT/Sources/smoke/main.swift" <<'S'
let v = version()
let r = try await runtimeCheck()
guard v == r else { fatalError("mismatch \(v) \(r)") }

import Foundation
final class Sink: LogSink, @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [LogRecord] = []
    func log(record: LogRecord) { lock.lock(); seen.append(record); lock.unlock() }
    var records: [LogRecord] { lock.lock(); defer { lock.unlock() }; return seen }
}
let sink = Sink()
try configureLogging(config: LoggingConfig(logDir: nil, maxLevel: .info), sink: sink)
logMessage(level: .info, category: "smoke", message: "callback")
guard sink.records.contains(where: { $0.subsystem == "veya" && $0.category == "smoke" && $0.message == "callback" })
else { fatalError("callback not delivered: \(sink.records)") }
print("ok \(v)")
S

EXTRA='"-lm"'
[ "$(uname)" = Linux ] && EXTRA='"-lm", "-ldl", "-lpthread"'
[ "$(uname)" = Darwin ] && EXTRA='"-framework", "Security", "-framework", "SystemConfiguration", "-framework", "CoreFoundation"'
[ -n "${WIN:-}" ] && EXTRA='"-lws2_32", "-luserenv", "-lbcrypt", "-lntdll", "-ladvapi32", "-lcrypt32", "-lsecur32", "-lncrypt", "-lole32", "-lshell32", "-lkernel32"'
cat > "$OUT/Package.swift" <<P
// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "smoke",
    targets: [
        .systemLibrary(name: "spotcoreFFI"),
        .executableTarget(
            name: "smoke", dependencies: ["spotcoreFFI"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.unsafeFlags(["-L", "$LIBDIR", "-lspotcore", $EXTRA])]),
    ]
)
P
cd "$OUT" && swift run smoke
