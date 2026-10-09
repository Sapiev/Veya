# ADR-008: Persistent metadata cache

- Status: Accepted
- Date: 2026-10-09

## Context

PBI-308 requires the library, playlists and item metadata to render at launch
from a local cache, then reconcile with the server. The plan named SQLite
through GRDB.

GRDB is a Swift library. Every Spotify service lives in the Rust core and
crosses into Swift through UniFFI (ADR-001). Before this decision, the
library cached each set as a JSON file and item metadata stayed in memory
only. Playlists had no cache.

## Decision

1. `spotcore` owns one SQLite database through `rusqlite` with its bundled
   SQLite. Swift opens it as a `MetadataStore` at
   `Caches/<bundle id>/Metadata.sqlite` and passes it to `LibraryService`,
   `MetadataService` and `PlaylistService`. Without a store, the services
   keep their in-memory behavior.
2. `PRAGMA user_version` sets the schema version. Each migration runs in one
   transaction. A file that is not readable as SQLite, or that has a newer
   version than the build knows, is deleted and created again. The data is
   a cache, so losing it costs only a refetch.
3. Revision IDs come from the server: the collection `sync_token` for each
   library set and the playlist `revision`. A playlist whose revision changes
   drops its stored tracks before the new window is written. Item metadata
   has no revision. An item fetched more than 7 days ago counts as a miss, so
   changes in playability reach the user.
4. Stale-while-revalidate: callers read `cached`, `cached_rootlist` or
   `cached_page` first, then call the network method, which writes the
   result back to the store.
5. `MetadataStore.clear` deletes all rows and increments a generation
   counter. A service write that started before a `clear` is skipped. This
   way, a refresh that is still in flight during sign-out cannot write the
   old account's data back. Sign-out calls `clear`.
6. The JSON library files are removed without migration. No released build
   wrote them.

## Consequences

- The cache logic is tested with `cargo test -p spotcore` and is not
  duplicated in Swift.
- Store calls are short synchronous SQLite calls behind a mutex on the
  caller's task. If profiling shows contention, move them to a blocking pool.
- The Settings "Reset" button calls the same `clear` when the Settings
  window ships (PBI-407).
