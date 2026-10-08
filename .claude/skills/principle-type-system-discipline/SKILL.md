---
name: principle-type-system-discipline
description: "Type design discipline: make illegal states unrepresentable, newtype semantic primitives, parse external data at boundaries, exhaust variants, keep invariants behind validated constructors. Cite by name when designing a Swift or Rust type, a UniFFI interface, or reviewing a function signature."
disable-model-invocation: true
---

# Type System Discipline

The type checker is a proof assistant. Use it to eliminate impossible states, mismatched primitives, and unhandled variants at compile time. A case the types let you ignore becomes a runtime failure the compiler could have stopped. Prefer defining errors and special cases out of existence over proliferating handlers; unrepresentable states, total functions, and interface redesign (the patterns below) are the tools.

Two grounding facts for this repo:

- **The Rust core (`core/spotcore`) is the authoritative source of domain types.** Playback state, track/album/playlist identity, and session state are Rust types first; the Swift app layer consumes them as UniFFI-generated projections, not as a second hand-maintained model. A Swift type that restates a shape spotcore already owns is a second definition of one shape, and it drifts the first time either side changes without the other.
- **The enforcement points are `cargo build`/`cargo clippy` on the Rust side and the Swift compiler on the generated bindings.** A type-design argument that neither can settle is a style preference. If the discipline below is real, it shows up as a build failure at the wrong call site, not a crash at runtime.

**The patterns:**

- **Make illegal states unrepresentable.** Model variants as an enum with associated values, not a struct with optional fields and booleans that can combine inconsistently. `enum PlaybackState { case idle; case loading; case playing(Track); case paused(Track); case error(PlaybackError) }` cannot express "paused with no track" or "playing and loading at once." A struct like `{ isPlaying: Bool; isLoading: Bool; currentTrack: Track?; error: Error? }` can represent both, and most of those combinations are meaningless. In Rust the same move is a sum type, `enum PlaybackState { Idle, Loading, Playing(Track), Paused(Track), Error(PlaybackError) }`, matched exhaustively rather than tracked as a struct of flags. If a bug forces the question "wait, can this combination actually happen?", the type is too loose.
- **Types are constructions, not restrictions.** Build the type up from the values you want instead of carving them out of a looser type with checks. In Rust this means private fields plus a constructor that returns `Result<T, E>`: a `TrackUri` or a non-empty play queue is built once, validated at the one entry point, and every downstream holder trusts it without re-checking. That is "parse, don't validate" — the type itself is the proof the invariant holds, so field access never needs a companion assertion.
- **Newtype semantic primitives.** Two values that are the same primitive underneath but mean different things should not be interchangeable. A Rust tuple struct (`struct TrackId(String)` vs `struct PlaylistId(String)`) or a distinct Swift struct wrapping a `String` stops a transposed argument from compiling instead of silently swapping two ids at a call site. UniFFI projects a newtype as its own Swift type the same way it projects any record — crossing the boundary does not force you back down to bare strings.
- **External data is untyped until parsed.** Spotify API responses, librespot session state, on-disk cache files, saved preferences. Have a parsing constructor at every boundary that turns untyped input (JSON, bytes, a loosely-typed FFI record) into the validated model, returning `Result`/`Err` there rather than letting an `Optional` or a force-unwrap carry the uncertainty three call sites downstream.
- **Don't lie to the type system.** A Swift force-cast (`as!`) or implicitly-unwrapped optional (`T!`) asserts a fact the compiler cannot see; a Rust `.unwrap()`/`.expect()` does the same at runtime. Each is a crash with a delay on it. Prefer `Result<Success, Failure>` over throwing-plus-optional combos for fallible operations, and prefer real `Optional` unwrapping (`if let`, `guard let`, `?`) over `!`. If you keep an unwrap or a force-cast, it earns a comment saying why the invariant is actually guaranteed.
- **Exhaustive matching is the compiler's job.** A Rust `match` over an enum must handle every variant or it fails to compile — no default arm papering over a case. A Swift `switch` over an enum is exhaustive the same way, as long as you resist adding a catch-all `default:` that would silently swallow new cases. When a variant is added later, the compiler, not a code review, should point at every site that needs to learn about it.
- **Choose value types and reference types deliberately.** A Swift `struct` copies; a `class` is shared and mutable through every reference to it. State that should have one obvious owner at a time — a `Track`, a snapshot of `PlaybackState` — is a struct. State that genuinely needs identity and shared mutation, such as a long-lived player or session controller, is a class, chosen on purpose rather than by default. Rust's borrow checker enforces the same discipline at compile time: it refuses code that would let two owners mutate the same state without synchronization, which is the data-race version of this principle.
- **Design Rust types so they cross the UniFFI boundary clean.** UniFFI turns Rust enums and structs into Swift enums and structs mechanically, but only if the Rust side is already shaped right. A Rust enum with associated data becomes a proper Swift enum with associated values. An integer tag plus a sibling struct of "the fields that apply when the tag is 2" becomes, on the Swift side, exactly the bag-of-optionals shape this principle argues against — reconstructed one layer down, at the one boundary where it is hardest to fix later. Model the sum type in Rust and let UniFFI project it; don't flatten it for the FFI and ask Swift-side code to reassemble the invariant.

**The tests:**

- "Can I write a comment explaining when this combination of fields is valid?" If yes, the type is too loose. Split it into an enum with associated values.
- "Do two of my function arguments share a primitive type but mean different things?" Newtype them — a Rust tuple struct or a wrapped Swift struct.
- "Where did this `unwrap()`, `expect()`, `!`, or `as!` come from?" Trace it to the boundary and return `Result`/`Optional` there instead.
- "If a new variant is added next month, will the compiler tell the next agent where to add a case?" If no, the match or switch isn't exhaustive.
- "Does this Rust type cross UniFFI as a clean enum, or does the Swift side have to reconstruct the invariant from a tag plus optional fields?" If the latter, push the variant modeling back into the Rust type.
- "Am I reaching for a class where a struct would do?" Reference semantics should be a deliberate choice about shared ownership, not a default.

For naming the concepts these types encode, call the Skill tool with `domain-modeling`.
