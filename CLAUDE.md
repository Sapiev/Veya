# Veya project conventions

Native macOS Spotify client. Swift (SwiftUI/AppKit) app layer, Rust core (`core/spotcore`) exposed to Swift via UniFFI. Architecture decisions: `docs/adr/`.

## Token efficiency default

Read less. Search first. Delegate hard. Reuse code. Write minimal. Fewest tokens, stay correct.

Before open file, ask "need this file?":
- No → don't open.
- Maybe → search first (`rg`), no browsing.
- Yes → read relevant part only.

Search → identify → read → implement. Never: browse dirs blind, read files on spec, search only after reading everything.

Target file reads: simple task <3 files, complex <10. Beyond → delegate. No curiosity reading.

## Priority order

1. Correctness
2. Reuse code
3. Context efficiency
4. Delegation
5. Speed
6. New abstractions

Existing pattern solves it → no new abstraction.

## Delegation

Default subagents for non-trivial work: many domains, growing investigation, large code changes, tests to write, review needed, special expertise. Don't burn main-thread context on subagent-able work.

- Parallelize independent work.
- Main thread clean; integrate results, don't reproduce.
- Architecture decisions stay main thread.
- Comment/code review → subagent that didn't author change; author defends own code if challenged.

Workflow: plan → fan out → integrate → verify through agents → deliver.

## Comments

Code explains itself first: good names, small functions, clear flow.

Comment only when code can't say it:
- non-obvious constraint
- invariant
- wire format or byte layout (esp. Rust/Swift UniFFI boundary)
- why workaround exists
- threat-model note

Short, descriptive, one idea, 1-2 lines. Never restate code, no decoration, no banners.

## Tests

Name exact invocation, not vague "add tests":
- Rust: `cargo test -p spotcore <pattern>`
- Swift: `xcodebuild test -scheme Veya -only-testing:<target>/<pattern>`, or run relevant test target in Xcode.
- UI: `xcodebuild test -project Veya.xcodeproj -scheme Veya -destination 'platform=macOS' -only-testing:VeyaUITests/<Class>/<test>`

Every change to what user sees/clicks in `Veya/` (screens, menus, buttons, banners, alerts) ships with XCUITest in `VeyaUITests/`, one file per area, tagged with PBI. Tests launch via **scenario**: `XCUIApplication.launch(.signedIn)` starts app on in-memory fakes, never Spotify or Keychain. New app state → new case in `Veya/UITestScenario.swift` (DEBUG-only) mirrored in `VeyaUITests/VeyaApp.swift`. Gotchas:
- Mark each test method `@MainActor`; target nonisolated by default.
- macOS static text string is its `value`, so predicates match `value`, not `label`; `staticTexts["exact text"]` matches either.
- Query by visible text first; `.accessibilityIdentifier` only for elements without stable text.

Visual changes are verified by screenshots you actually look at, not only green tests. Shell `screencapture` is blocked; instead:
- In the test, `attachScreenshot(of: app.windows.firstMatch, named: "<name>")` (`VeyaUITests/Screenshot.swift`).
- Run `scripts/ui-screenshots.sh -o <scratchpad>/shots VeyaUITests/<Class>[/<test>] ...`; it prints `<name>\t<png path>` per screenshot.
- Read each PNG. Measure alignment/spacing numerically (pixels via a small `NSBitmapImageRep` script), not by eye.

## Accessibility

Every new/changed UI element in `Veya/` accessible from day one (PBI-801 baseline), not retrofitted:
- VoiceOver: meaningful label on icon-only controls, decorative images hidden, related views combined, state exposed as value/traits.
- Keyboard: reachable, operable without mouse (focus, shortcuts, menu equivalents).
- Text scales with app text size setting; no fixed font sizes.
- Respect contrast, Reduce Motion / Reduce Transparency.
- New screens get `assertAuditPasses(app, "<screen>")` (`VeyaUITests/AccessibilityAudit.swift`) in UI test.

See `ios-accessibility` and `apple-design` skills.

After changes: update tests, run relevant ones, report results. Rust core logic tested in Rust directly, not only indirectly via Swift tests crossing FFI.

Behavior-preserving refactor: record current output *first*, prove unchanged after. Pinned before-output required, not just green tests.

Verify each unit before next. Never batch sweep and check once at end. See `principle-sequence-verifiable-units`.

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

No long explanations, architecture essays, repeating requirements, explaining stdlib/framework basics. Assume experienced engineer. Return only what moves work forward.

## PBI completion

PBIs are issues `PBI-xxx · Title` in `Sapiev/Veya`, tracked in project https://github.com/users/Sapiev/projects/5 (find: `gh issue list -R Sapiev/Veya --search "PBI-xxx in:title"`). PBI not finished until its issue updated (`gh issue edit`):
- Tick `- [x]` each acceptance criterion verified against repo; leave unmet `- [ ]` with short parenthetical reason.
- Update `**Status:**` line in issue body and project Status field: `In progress`, `In review` (PR open, body names branch), `Done` on merge to develop.
- PR body says `Closes #<issue>` so merge closes it.

## Other conventions

- Never commit unless explicitly asked; leave changes uncommitted for review.
- Build caches and old build output may be deleted without asking: `cargo clean` in `core/`, `~/Library/Developer/Xcode/DerivedData/Veya-*`, and `.xcresult` bundles and screenshots in your scratchpad. `core/target` grows to tens of GB. Required once your job is done (after the last test run), and on ENOSPC before rebuilding. Never delete anything else. After deleting DerivedData, run `xcodebuild -resolvePackageDependencies -project Veya.xcodeproj -scheme Veya` so Xcode has Sparkle again; retry once if it fails while Xcode is open.
- Never use em dash "—"; use hyphen "-".
- Always verify via proper tests before claiming done.
- Never suppress, skip, ignore, or exclude failing test/file to pass checks. Fix root issue, add coverage for changed behavior.
- Task done → suggest commit message to user (don't commit).
- Every state-mutating op or lifecycle step (token refresh, cache writes, migrations) must answer: runs twice? last run crashed halfway? See `principle-make-operations-idempotent`.
- Corrected same thing twice → encode structurally. Ladder strongest first: unrepresentable type > compiler/lint check > shared helper > runtime guard. Then delete prose explaining it. See `principle-encode-lessons-in-structure`.
- Non-trivial sweep across files → write rerunnable script/codemod, not hand edit per file. See `principle-build-the-lever`.

## Skills

`.claude/skills/` holds process and principle skills adapted from prior projects (debugging, TDD, refactoring, domain modeling, Apple HIG design/animation review, security review for native app handling OAuth tokens, type-system discipline across Rust/Swift boundary, more). Check there before improvising process.