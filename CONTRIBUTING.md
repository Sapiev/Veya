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
section. In short: Xcode 27+, Swift 6, Rust stable ≥ 1.85.

Before you open the project for the first time, build the Rust core once:

```sh
scripts/build-xcframework.sh debug
```

This produces `SpotCoreKit/spotcoreFFI.xcframework` and the generated Swift
bindings, which Xcode needs to resolve the `SpotCoreKit` package. After that,
the `Veya` scheme rebuilds the core automatically when `core/` changes.

### Signing

Without a team, Xcode signs the app to run locally. To sign with your own
team or bundle ID prefix, create `Config/Local.xcconfig` (gitignored):

```
DEVELOPMENT_TEAM = ABCDE12345
VEYA_BUNDLE_ID_PREFIX = com.example
```

Do not pick a team in Xcode's Signing & Capabilities tab. Xcode writes it
into `project.pbxproj`, where it overrides every contributor's
`Local.xcconfig`.

Release builds, signing and building a DMG from source:
[docs/release.md](docs/release.md).

## Making a change

1. Fork and create a branch off `main`.
2. Keep changes focused on a single PBI or issue; avoid unrelated refactors
   in the same PR.
3. Add or update tests for new logic (Swift Testing / XCUITest, `cargo test`).
4. Run SwiftLint/SwiftFormat and `cargo clippy -D warnings` / `rustfmt` where
   applicable. `scripts/install-linters.sh` installs the versions CI pins
   into `.tools/bin`.
5. Update docs and CHANGELOG, and add an ADR under `docs/adr/` for any
   architectural decision.

## Translations

Veya ships in English and Polish. All UI text lives in String Catalogs
(`Veya/Localizable.xcstrings`, `Veya/InfoPlist.xcstrings`); pass text to
SwiftUI as a literal or `String(localized:)`, never as a plain `String`, and
format dates, durations and numbers with `.formatted()`. Building in Xcode
adds new strings to the catalog. `scripts/check-localizations.sh` (run in CI)
fails while any string lacks a reviewed Polish translation.

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
