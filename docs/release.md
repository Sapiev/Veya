# Releasing Veya

A release is a tag. Pushing `v<version>` runs `.github/workflows/release.yml`,
which builds the app, signs it with the project's self-signed certificate,
wraps it in a DMG (PBI-901), publishes the GitHub release, adds the update to the Sparkle
appcast (PBI-902) and, for stable versions, updates the Homebrew cask
(PBI-903).

Veya has no paid Apple Developer account, so releases are not notarized.
macOS blocks the first launch once; users allow it in System Settings ›
Privacy & Security › Open Anyway (or `xattr -dr com.apple.quarantine
/Applications/Veya.app`). Sparkle updates install without asking again. The
self-signed certificate is not trusted by Gatekeeper; it exists to give every
release the same identity, which macOS ties the Keychain sign-in and privacy
permissions to. An ad hoc signature changes with every build, so users would
sign in again after each update. Because the certificate has no Apple Team ID,
`scripts/release.sh` adds `com.apple.security.cs.disable-library-validation`,
without which the app cannot load Sparkle.framework.

## Cutting a release

1. Move the `## [Unreleased]` entries in `CHANGELOG.md` under
   `## [1.2.0] - 2026-10-14`. The workflow stops before building if the
   version has no entry; that text becomes the GitHub release notes and the
   in-app update notes.
2. Tag `develop` and push: `git tag v1.2.0 && git push origin v1.2.0`. Always
   tag commits on `develop`: the build number is the commit count, and
   Sparkle offers an update only when that number is higher than the
   installed one, so a tag on a shorter side branch would never be offered.

A version with a suffix (`v1.2.0-beta.1`) is a beta: a GitHub prerelease on the
appcast's `beta` channel, offered only to people who turned on Settings ›
Advanced › Include beta versions, and not pushed to Homebrew.

Re-running a failed workflow is safe: the DMG asset is replaced, the appcast
item for that build is replaced rather than duplicated, and an unchanged cask
is not recommitted.

## One-time setup

GitHub repository secrets:

| Secret | Value |
|---|---|
| `SIGNING_CERT_P12_BASE64` | `veya-signing.p12` from `scripts/make-signing-certificate.sh`, base64 |
| `SIGNING_CERT_P12_PASSWORD` | `veya-signing.password` from the same run |
| `SPARKLE_ED_PRIVATE_KEY` | Output of Sparkle's `generate_keys -x <file>` |
| `HOMEBREW_TAP_TOKEN` | Fine-grained token with contents write on `Sapiev/homebrew-veya` |

Also:

- Signing certificate: run `scripts/make-signing-certificate.sh ~/veya-signing`
  once, then
  `base64 -i ~/veya-signing/veya-signing.p12 | gh secret set SIGNING_CERT_P12_BASE64` and
  `gh secret set SIGNING_CERT_P12_PASSWORD < ~/veya-signing/veya-signing.password`.
  Back the folder up somewhere safe: a new certificate is a new app identity,
  and every user would have to sign in again after the next update.
- Sparkle key: run Sparkle's `bin/generate_keys` (from the
  [release tarball](https://github.com/sparkle-project/Sparkle/releases)),
  put the printed public key in `SPARKLE_PUBLIC_ED_KEY` in
  `Config/Shared.xcconfig`, and export the private key for the secret above.
  A signed release without the whole public key fails, since it could never
  verify an update.
- GitHub Pages: create an empty `gh-pages` branch and serve Pages from it. The
  workflow creates `appcast.xml` there on the first release.
- Homebrew: create the `Sapiev/homebrew-veya` tap repository. The workflow
  renders `packaging/homebrew/veya.rb` into its `Casks/veya.rb`, so users run
  `brew install --cask sapiev/veya/veya`. The official homebrew-cask
  repository is not an option: it is phasing out apps that fail Gatekeeper,
  which an app that isn't notarized does.

## Building from source

The same script, without `SIGNING_IDENTITY`, produces an ad hoc signed DMG:

```sh
scripts/release.sh 1.2.0     # build/release/Veya-1.2.0.dmg
```

It needs the toolchain from CONTRIBUTING.md. The build number is the commit
count, so building a tagged commit with the same Xcode and Rust toolchain
(`core/rust-toolchain.toml`) gives the same version and build. macOS asks you
to approve an ad hoc build on first open (System Settings › Privacy & Security
› Open Anyway). A Release build checks the official appcast and can update
itself to an official release; a fork that ships its own builds sets its own
`SPARKLE_PUBLIC_ED_KEY` and `SUFeedURL`, or clears the key to turn updates off.

To sign a release locally, import the certificate into a keychain and set
`SIGNING_IDENTITY="Veya Release"` (and `SIGNING_KEYCHAIN` if that keychain is
not on the search list).
