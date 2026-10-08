# Contributing to Veya

Thanks for your interest in contributing. Veya is an unofficial, open-source
Spotify client for macOS - see the [README](README.md) for the disclaimer and
the plan document for architecture and backlog.

## Before you start

- Read the [Code of Conduct](CODE_OF_CONDUCT.md).
- For anything beyond a small fix, open an issue first to discuss the
  approach before writing code.
- Check the backlog (PBIs) in the plan document to see if the work is already
  scoped and what it depends on.

## Development setup

Repo layout and toolchain are described in the plan document's "Tech stack"
section. In short: Xcode 26+, Swift 6, Rust stable ≥ 1.85.

Before you open the project for the first time, build the Rust core once:

```sh
scripts/build-xcframework.sh debug
```

This produces `SpotCoreKit/spotcoreFFI.xcframework` and the generated Swift
bindings, which Xcode needs to resolve the `SpotCoreKit` package. After that,
the `Veya` scheme rebuilds the core automatically when `core/` changes.

## Making a change

1. Fork and create a branch off `main`.
2. Keep changes focused on a single PBI or issue; avoid unrelated refactors
   in the same PR.
3. Add or update tests for new logic (Swift Testing / XCUITest, `cargo test`).
4. Run SwiftLint/SwiftFormat and `cargo clippy -D warnings` / `rustfmt` where
   applicable.
5. Update docs and CHANGELOG, and add an ADR under `docs/adr/` for any
   architectural decision.

## Pull requests

- Fill in the PR template, including the Definition of Done checklist.
- PRs require at least one review and a green CI run before merge.
- Prefer small, reviewable PRs over large ones.

## Commit sign-off (DCO)

Commits must include a `Signed-off-by` line (`git commit -s`) certifying you
have the right to submit the contribution under the project's license.

## Reporting bugs and requesting features

Use the issue templates. For security vulnerabilities, follow
[SECURITY.md](SECURITY.md) instead of filing a public issue.
