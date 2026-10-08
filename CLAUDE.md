# Veya project conventions

Native macOS Spotify client. Swift (SwiftUI/AppKit) app layer, Rust core
(`core/spotcore`) exposed to Swift via UniFFI. See `docs/adr/` for
architecture decisions.

## Token efficiency default

Read less. Search first. Delegate hard. Reuse code. Write minimal.
Fewest tokens, stay correct.

Before opening a file, ask "need this file?":
- No → don't open it.
- Maybe → search first (`rg`) instead of browsing.
- Yes → read only the relevant part.

Search → identify → read → implement. Never: browse directories blind,
read files on spec, search only after reading everything.

Target file reads: simple tasks under 3 files, complex tasks under 10.
Beyond that, delegate. No reading for general curiosity.

## Priority order

1. Correctness
2. Reuse code
3. Context efficiency
4. Delegation
5. Speed
6. New abstractions

If an existing pattern solves the problem, don't add a new abstraction.

## Delegation

Default to subagents for non-trivial work: many domains touched, growing
investigation, large code changes, tests to write, review needed, or
special expertise required. Don't burn main-thread context on work a
subagent can do.

- Parallelize independent work.
- Keep the main thread clean; integrate results, don't reproduce them.
- Architecture decisions stay on the main thread.
- Comment/code review goes to a subagent that didn't author the change;
  the author defends their own code if challenged.

Workflow: plan → fan out → integrate → verify through agents → deliver.

## Comments

Code explains itself first: good names, small functions, clear flow.

Comment only when code cannot say it:
- non-obvious constraint
- invariant
- wire format or byte layout (especially at the Rust/Swift UniFFI boundary)
- why a workaround exists
- threat-model note

Short and descriptive, one idea, one or two lines. Never restate code,
no decoration, no banner comments.

## Tests

Name the exact invocation, not a vague "add tests":
- Rust: `cargo test -p spotcore <pattern>`
- Swift: `xcodebuild test -scheme Veya -only-testing:<target>/<pattern>`,
  or run the relevant test target from Xcode.

After changes: update tests, run the relevant ones, report results.
Logic that lives in the Rust core should be tested there directly, not
only indirectly through Swift-level tests crossing the FFI boundary.

For a refactor that must not change behavior: record the current output
*first*, then prove it's unchanged after. A pinned before-output is
required, not just green tests.

Verify each unit before starting the next. Never batch a sweep of
changes and check once at the end — see `principle-sequence-verifiable-units`.

## Output discipline

Default response shape:

```
Completed:
- result

Changed Files:
- file list

Tests:
- results

Blockers:
- if any
```

Avoid long explanations, architecture essays, repeating requirements
back, or explaining standard libraries/framework basics. Assume an
experienced engineer. Return only what's needed to move the work forward.

## Other conventions

- Never commit changes unless explicitly asked; leave changes
  uncommitted for review.
- Never use an em dash "—"; use a hyphen "-" instead.
- Always verify work by running the proper tests before claiming done.
- Never suppress, skip, ignore, or exclude a failing test/file to make
  checks pass. Fix the underlying issue and add coverage for the
  changed behavior.
- After a task is done, suggest a commit message to the user (don't
  commit it yourself).
- Every state-mutating operation or lifecycle step (token refresh,
  cache writes, migrations) must answer: what if it runs twice, what if
  the last run crashed halfway. See `principle-make-operations-idempotent`.
- Corrected on the same thing twice means encode it structurally.
  Ladder strongest first: unrepresentable type > compiler/lint check >
  shared helper > runtime guard. Then delete the prose explaining it.
  See `principle-encode-lessons-in-structure`.
- A non-trivial sweep across files means write the rerunnable
  script/codemod, not a hand-applied edit per file. See
  `principle-build-the-lever`.

## Skills

`.claude/skills/` holds process and principle skills carried over and
adapted from prior projects (debugging, TDD, refactoring, domain
modeling, Apple HIG-driven design/animation review, security review for
a native app handling OAuth tokens, type-system discipline across the
Rust/Swift boundary, and more). Check there before improvising a process
from scratch.
