---
name: tdd
description: Test-driven development discipline for this repo - the red-green loop, what makes a test worth keeping, and the three anti-patterns that produce tests which cannot fail. Use when building a feature or fixing a bug test-first, when adding coverage for changed behavior, or when reviewing whether an existing test actually verifies anything.
---

# Test-Driven Development

TDD is the red-green loop. This skill is the reference that makes the loop produce tests worth keeping: what a good test is, where tests go, the anti-patterns, and the rules of the loop. Every section applies on every cycle. Consult them before and during the loop, not after.

See [tests.md](tests.md) for good and bad examples, and [mocking.md](mocking.md) for where mocking is allowed.

## Commands

| Scope | Command |
|---|---|
| Rust core unit tests | `cargo test` (run from `core/spotcore`) |
| Rust one test | `cargo test <name>` (substring-matches test names) |
| Swift unit tests | `xcodebuild test -scheme Veya -destination 'platform=macOS'` |
| Swift one test | `xcodebuild test -scheme Veya -destination 'platform=macOS' -only-testing:VeyaTests/<Suite>/<method>` |
| Rust types/lint | `cargo check` and `cargo clippy --all-targets` (from `core/spotcore`) |
| Swift build check | `xcodebuild build -scheme Veya` |
| whole suite | `cargo test` in `core/spotcore`, then `xcodebuild test -scheme Veya -destination 'platform=macOS'` |

Run the narrowest command that covers the slice. The whole suite is a final check, not a loop step. Prefer the Rust command whenever the slice under test is logic that lives in `core/spotcore`: it runs in milliseconds with no simulator or app launch required.

## What a good test is

Tests verify behavior through public interfaces, not implementation details. Code can change entirely; tests should not. A good test reads like a specification: "playback resumes at the exact position after a seek" tells you exactly what capability exists, and it survives refactors because it does not care about internal structure.

Use the domain vocabulary the code already uses so test names and interface names agree. When the domain terms themselves are unsettled, call the Skill tool with `domain-modeling`.

## Seams: where tests go

A **seam** is the public boundary you test at: the interface where you observe behavior without reaching inside. Tests live at seams, never against internals.

**Name the seams before writing tests.** Write the seams under test into `ai-output/work/[name]/spec.md` (or into the task brief when there is no spec) before the first test. You cannot test everything, so fixing the seams up front is how testing effort lands on critical paths and complex logic instead of on every edge case. Naming them in writing is also what makes the work delegable: a `test-writer-fixer` subagent can execute the loop against a written seam list without a round trip.

Escalate to the user only when the seam choice is genuinely contested, for example when two seams disagree about who owns an invariant, or when testing at the honest seam would require a change to a published contract. A seam that is merely unstated is not contested: name it, record it, proceed.

When the shape of the interface is itself in question (how deep the module is, where the seam belongs, what the interface should expose), call the Skill tool with `codebase-design` for the vocabulary. It is the shared source of the module, interface, depth, seam, adapter, leverage and locality terms, and it is a reference to consult, not a session to run.

**Push coverage down to the Rust core.** Veya is a Swift app over a Rust core (`core/spotcore`) exposed through UniFFI. When behavior belongs to the Rust layer — track or session parsing, queue logic, anything wrapping librespot — write the test in Rust against the Rust function directly (`cargo test`: no simulator, no app launch, sub-second). Covering that same logic only with a Swift test that crosses the FFI boundary is the worse seam: it is slower, it couples the test to UniFFI's generated bindings instead of to the logic, and a failure tells you less about where the bug actually is. Reserve Swift-level tests for the seam Swift actually owns — wiring the generated bindings into view models and app state — not for re-verifying logic a Rust test already covers.

**Test the view model, not the view.** SwiftUI view bodies are a poor seam: they are declarative, recomputed on every render, and not something XCTest or Swift Testing can assert against directly without a full UI test (slow, flaky, needs a host app). Put logic in an `@Observable` (or legacy `ObservableObject`) view model and test that type directly: construct it, call its methods, assert on its published state. Reserve actual UI tests (XCUITest) for the few flows where the rendering and interaction itself is the thing under test, not as a stand-in for unit-testing the view model's logic.

## Anti-patterns

- **Implementation-coupled**: mocks internal collaborators, tests private methods, or verifies through a side channel instead of through the interface. The tell: the test breaks when you refactor but behavior has not changed. See [tests.md](tests.md) for the one qualified exception, where stored bytes are themselves the published contract.
- **Tautological**: the assertion recomputes the expected value the way the code does (`XCTAssertEqual(cacheKey(uri), sha256(uri))` in Swift, or `assert_eq!(cache_key(uri), sha256(uri))` in Rust — a hash or snapshot derived by hand the same way the code derives it, a constant asserted equal to itself), so it passes by construction and can never disagree with the code. **Expected values must come from an independent source of truth: a known-good literal, a worked example, or the spec. Never from the implementation.** This is the load-bearing rule in this repo. Frozen protocol vectors exist precisely so parsing and hashing expectations are literals checked in once and never re-derived by the code under test. A test that recomputes its expectation with the same function it is testing verifies nothing at all: it would pass just as happily if the logic changed underneath it.
- **Horizontal slicing**: writing all tests first, then all implementation. Bulk tests verify *imagined* behavior. You test the *shape* of things rather than user-facing behavior, the tests go insensitive to real changes, and you commit to test structure before understanding the implementation. Work in **vertical slices** instead: one test, one implementation, repeat. Each test is a **tracer bullet** that responds to what the last cycle taught you. This ban holds even under delegation: a subagent asked for "tests for module X" must still deliver them slice by slice, not as a batch.

## Rules of the loop

- **Red before green.** Write the failing test first, then only enough code to pass it. Confirm it fails for the reason you expect, not because of a typo or a missing import. Do not anticipate future tests or add speculative features.
- **One slice at a time.** One seam, one test, one minimal implementation per cycle.
- **Cleanup happens in the loop, once green.** When the slice is green, clean it up immediately: drop the scaffolding, collapse the duplication the slice introduced, fix the naming. Re-run the same narrow command to confirm still green. Leaving cleanup for later means it never happens, and the next slice builds on the mess. Keep cleanup inside the slice you just made green rather than roaming.
- **Review is a separate pass, not the owner of refactoring.** A review pass (`code-review` plugin, or a `reviewer` subagent) reads the finished change for correctness, security and design. It may ask for further refactoring, but refactoring the slice you just wrote is your job and it happens before review, not because of it.
- **Never make a check pass by weakening it.** No skipping, no `#[ignore]` in Rust or a disabling trait / commented-out method in Swift used to dodge a failure, no loosened assertion, no swallowed error to get to green. If a test is wrong, fix the test deliberately and say so.

## Finishing

Run `cargo fmt` and `cargo clippy --all-targets` on anything touched in `core/spotcore`, run Xcode's formatter (or SwiftFormat, if the project later adopts one) on anything touched in the Swift app, and the narrow test command for the slice. Run `fallow` before declaring done, as AGENTS.md requires.

Leave the tree uncommitted. Report as **Completed / Changed Files / Tests / Blockers**, suggest a conventional-commit name (for example `test(spotcore): cover session config device id generation`), and log the outcome in `ai-output/work/[name]/progress.md`.
