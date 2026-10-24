# ADR-003: Credential storage and auto sign-in

- Status: Accepted
- Date: 2026-10-09

## Context

PBI-102 makes a returning user sign in without seeing the login page. Two
decisions are needed:

1. What the app stores after the first sign-in.
2. Where the app stores it.

The OAuth flow from ADR-002 returns an access token and a refresh token.
The access token only opens a librespot `Session`. When the access point
accepts it, the session receives reusable credentials
(`AUTHENTICATION_STORED_SPOTIFY_CREDENTIALS`). librespot uses these
credentials to reconnect without OAuth.

The Keychain offers two stores on macOS:

- The data-protection keychain supports `kSecAttrAccessGroup`. It needs an
  `application-identifier` entitlement, so the app must be signed with a
  Development Team.
- The legacy login keychain needs no entitlement. Each item has an ACL that
  trusts only the application that created the item.

`Shared.xcconfig` leaves `DEVELOPMENT_TEAM` empty, and the app has no
entitlements file. Builds are signed ad hoc, so the data-protection keychain
returns `errSecMissingEntitlement`.

## Decision

- The app stores librespot's reusable credentials, not the OAuth tokens.
  `spotcore` encodes them, with the session's device ID, into an opaque,
  versioned blob. Swift does not parse the blob.
- The blob is a generic-password item in the legacy login keychain. The
  service is the bundle identifier and the account is a fixed key. The item
  uses the default ACL, which trusts only Veya. Nothing goes to disk outside
  the Keychain.
- On launch, the app connects with the stored blob. Two failures delete the
  item and show the sign-in screen: the access point rejects the credentials,
  or the blob does not decode. A network failure keeps the item and shows a
  retry button. The app deletes the item only if it still holds the blob
  that failed, so a newer sign-in is never lost.
- If the Keychain read fails for a reason other than a missing item, the
  app shows a Keychain error with Try Again and Sign In Again. It does not
  fall back to the sign-in screen without a message.
- The app has one window and one session.
- After each successful connect, the app saves the blob again. Saving
  updates the item if it exists, and adds it otherwise, so a repeated save
  has the same result.

## Consequences

- The refresh token is not kept. If the reusable credentials stop working,
  the user signs in through the browser again.
- An ad-hoc signature changes on every rebuild. In development, macOS can
  ask whether the rebuilt app may read the item.
- Follow-up: when release signing has a Team ID, move the item to the
  data-protection keychain with a `keychain-access-groups` entitlement scoped
  to `$(AppIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER)`, and migrate the
  existing item once.
