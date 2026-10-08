---
name: refactoring
description: "Behavior-preserving structural change: pin the contract with a characterization test before anything moves, then prove the reader-load delta with fallow or revert. Use for rename, extract, inline, dedupe, restructure, move-this-module, tidy-up-this-area."
disable-model-invocation: true
---

# Refactoring

You own the contract. The structure changes; the behavior does not.

For "refactor", "rename", "extract", "inline", "dedupe", "restructure", "move this module", "tidy up this area". Distinct from feature work, which adds behavior, and from a bug fix, which corrects it.

A refactor that smuggles in a behavior change loses its safety net. If the cleanup reveals a missing feature or a real bug, split it out and ship the structural change first against the pinned contract. A redesign is allowed, but name it as one and treat it as feature work. Large cross-cutting structural work (a migration across many call sites, a coordinated reshape of several subsystems) belongs to the Skill tool with `figure-it-out`; this playbook is the focused-to-medium change.

For the vocabulary of module depth, interface width, and seams, call the Skill tool with `codebase-design`. Do not restate it here.

## 1. Pin the behavior contract first

Before any structure moves:

- Call the Skill tool with `how` to learn what the affected subsystem actually guarantees.
- Write a characterization test, a snapshot, or an equivalence harness that captures current behavior. The pin turns "refactor" into a checkable claim.
- If the area has no coverage, the pin is the first thing you write. `tsc --noEmit` and `bunx biome check` are not a pin; they check shape, not behavior.

Where the pin lives:

| Area | Pin |
| --- | --- |
| API route or server module | `bun run test:api <pattern>` |
| Frontend logic | `bun run test:frontend <pattern>` |
| One file | `bun test <path>` |
| A React component's rendered output | `bun run --filter frontend test:storybook` and `test:storybook:dark` |
| A user flow across the stack | `bun run test:pw:docker <pattern>`, report at `apps/frontend/test-results/e2e-docker-report.json` |
| A page whose behavior is hard to assert offline | the `browser` tool, recording the observed states before you touch anything |

## 2. Find the callers before you move anything

Call the Skill tool with `blast-radius` for what a structure move breaks outside the diff. `lsp references` gets the direct callers in one call; the blast radius is the part a symbol search cannot reach: string keys, dynamic dispatch, serialized shapes, docs, test fixtures.

## 3. Name the structure the code is missing

A state machine over scattered booleans. A table or registry over spread-out branching. A typed model over repeated shape assumptions. A reducer over ad hoc mutations. For the typed-model case specifically, `principle-type-system-discipline` is the standard to hold.

Boring code stays when the shape is already clear and local. The reshape must delete branches or make invalid states unrepresentable; it must not merely add indirection.

## 4. Name the target shape

State what the module layout, types, and call graph should be if built today, not the smallest edit from where they are. If the target crosses a function boundary, run a `backend-architect` or `frontend-developer` subagent for a design pass before the move.

## 5. Subtract before you add

Delete dead weight, collapse one-caller wrappers, drop redundant validators, remove orphan references. `fallow` names the dead code for you. The smallest change that reaches the target shape ships. A speculative cleanup that "might help" gets reverted, not left to ride.

## 6. Move in small behavior-preserving steps

Each step keeps the pin green. That is `principle-sequence-verifiable-units` applied to structure: no step begins before the previous one is verified.

- For an API reshape, migrate every caller and delete the old API in the same wave. No compatibility shims, no parallel old-and-new paths, no deprecated re-exports.
- Prefer `lsp rename` and `ast_edit` codemods over hand edits for mechanical moves.
- Spot-check every rename against the actual files. Renames silently miss usages in strings, prose, and back-references.
- Delegate mechanical edits to a `sonic` or `task` subagent with a tight scope (file paths, the names being moved, the behavior to hold), and review the diff yourself.

## 7. Prove behavior is unchanged on the real artifact

"It compiles" is not proof. Re-run the pin from step 1 on its own surface. For a larger reshape, run an equivalence check: a script that diffs old against new outputs, or a recorded baseline replayed against the new code. Own the verification yourself; a delegate's "looks good" summary is not evidence.

## Anti-shortcut clauses

A behavior-preserving change is exactly where the temptation to bend the check lives, because the check is the only thing standing between you and "done". These are a specific instance of the AGENTS.md rule that failures are never suppressed to make a check pass:

- **No harness modifications.** You do not edit the characterization test, the Storybook story, the Playwright spec, or the assertion tolerance to make the diff pass.
- **No baseline tampering.** You do not re-record a snapshot or a screenshot baseline to absorb a delta. If the baseline itself looks wrong, stop and ask; do not edit it.
- **No restructuring to satisfy the check.** You do not reshape a component so the diff goes green. That inverts the whole exercise: the pin defines correct, the structure is what is under test.

A nonzero delta is a fail. Investigate it; do not wave it through.

## 8. Prove the change earns its place

The success measure is reduced reader load: fewer layers between a question and its answer, less hidden state, fewer indirections that have only one consumer. Measure it rather than asserting it.

Run `fallow` before and after and quote the delta: complexity hotspots, duplication, cycles, architecture boundary violations. A refactor that leaves complexity and duplication flat has not reduced reader load in any way a reader can check.

If the diff does not lower reader load somewhere, revert it.

## Finish

Leave the tree uncommitted. Report as:

- **Completed**: the structure that changed, the pin you held it against, the equivalence proof, the reader-load delta with the `fallow` numbers, what shipped and what got reverted. No new behavior.
- **Changed Files**
- **Tests**: the pin, green before and after.
- **Blockers**

Suggest a conventional commit name, for example `refactor(vault): replace boolean flags with an epoch state machine`. Where the work split into a subtraction pass and a reshape pass, suggest one name per slice so a reviewer can see the ordering. Log the outcome in `ai-output/work/[name]/progress.md`.
