# ADR-011: Linking spotcore from Swift on Windows and Linux

- Status: Proposed
- Date: 2026-10-24

## Context

The cross-platform plan (PBI-X02) needs Swift 6.3 on Windows and Linux to
call `spotcore` through the UniFFI Swift bindings, including an async call
and a callback interface (`LogSink`). `spikes/swift-smoke.sh` proves it on
Linux x64/arm64 and Windows x64/arm64 in CI.

## Decision

- **Link the static lib through a `systemLibrary` target** `spotcoreFFI`.
  The modulemap from `uniffi-bindgen` is patched to add `header
  "spotcore_audio.h"`; the generated Swift compiles into the app target.
- **Swift 5 language mode** for the generated sources
  (`.swiftLanguageMode(.v5)`). Swift 6 mode is untried.
- **Link flags per OS** (`-L <libdir> -lspotcore` plus):
  - Linux: `-lm -ldl -lpthread`
  - Windows: `-lws2_32 -luserenv -lbcrypt -lntdll -ladvapi32 -lcrypt32
    -lsecur32 -lncrypt -lole32 -lshell32 -lkernel32`; the lib is
    `spotcore.lib`, and the path passed to the linker must be a mixed
    path (`cygpath -m`).
- **Windows toolchain**: Swift 6.3-RELEASE via `compnerd/gha-setup-swift`
  with `build_arch` set per runner. The default amd64 toolchain crashes on
  the arm64 runner.
- **Linux container** `swift:6.3-noble` needs `curl ca-certificates gcc`,
  and `CARGO_HOME`/`RUSTUP_HOME` pinned because the image overrides `HOME`.

## Consequences

- Any new system library pulled in by `spotcore` dependencies must be added
  to the Windows list; a missing one shows as an unresolved symbol at link.
- Moving to Swift 6 language mode needs the generated bindings to be
  concurrency-clean first.
