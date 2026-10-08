---
name: figure-it-out
description: Designs an auditable playbook when no narrower one fits: a large migration, an ambitious multi-part change, or work a human reviews after stepping away. Scales rigor to blast radius, builds the verification harness before the work, and logs decisions to progress.md. Use when the user says "figure it out", hands over a large migration or cross-cutting change, or when no narrower playbook applies.
disable-model-invocation: true
---

# Figure it out

When the task matches no playbook, design one. The deliverable before any code is the workflow itself: a sequence of phases that scales rigor to the task, runs the scientific method, and leaves a decision trail a human can audit after stepping away. Bias toward more rigor. The cost of building the wrong thing dwarfs the cost of being careful.

Do not reinvent a playbook you already have. A focused single-unit bug fix, perf pass, or feature routes to the normal flow. A large or cross-cutting version of one (a migration across many call sites, an ambitious multi-part change), or work the user reviews after stepping away, belongs here. The rigor and the audit trail are the point.

Open a todolist with the phases below as items.

## Phase A: Frame

Ground first, then commit. Grounding starts with `graphify query "<topic>"` per AGENTS.md, falling back to `grep`, `glob`, and `lsp` because `graphify-out/` is empty today. Do not start the run until you can state:

- **The definition of done as a falsifiable predicate.** Write it before the run starts. Not "audit log is tamper-evident" but "`bun run test:api audit` passes, and mutating any row in a sealed epoch makes chain verification fail with `ChainMismatch`". If it cannot be checked, it is not done.
- **Scope, quantified.** Rough units and effort, plus the blockers grounding surfaced. Raise them before spending hours.
- **The rigor level, biased high.** Scale to blast radius, not to effort: a one-way door (wire format, signature domain, migration, frozen vector) earns more; a reversible local change earns less. Call the Skill tool with `blast-radius` to size it. Rigor means gates and artifacts, not trying harder.

Present the framing and the tradeoffs before committing to a long run. Reversible work proceeds without asking, but a multi-hour run earns one checkpoint.

## Phase B: Design the workflow

Decompose into atomic, independently-landable units. Sequence **riskiest unknown first** so option value stays high: resolve the thing that could invalidate the plan while the plan is still cheap to change.

- **Build the verification harness before the work, and capture the baseline from the PRE-change state.** This is the core move. The check must read as old value versus new value, so the harness has to exist and run against unmodified code first. A harness written after the change only proves the change agrees with itself.
- For a design decision with real alternatives, Call the Skill tool with `codebase-design` and run a single design pass. One pass. Re-deciding a settled design is over-engineering.
- Decide what fans out. Parallelize via `task` only across genuine seams, and keep each worker's files disjoint (Call the Skill tool with `principle-separate-before-serializing-shared-state`). Read-only reconnaissance units go to `scout`; only writing units get a writing agent. Do not over-fan.
- Write the designed phase list down in `ai-output/work/[name]/spec.md`. That list is what the human reviews.

Then put the design into motion: add its steps to the todolist as concrete items, run each under the Phase C loop, and write the Phase D log as each step lands rather than at the end.

## Phase C: Run the loop

Each unit is an experiment: state the hypothesis, make the smallest change, measure against the predicate on the real artifact, keep it if it advanced, revert it if it did not. Verify each unit before starting the next instead of batching checks at the end (Call the Skill tool with `principle-sequence-verifiable-units`).

- Verify by inspecting the artifact, never a self-report. **When something passes too easily, suspect the observation method before the system. A blank screenshot passes a lazy gate.**
- Audit a delegate's artifacts yourself before trusting them. Read the diff, run the check.
- A verdict is VERIFIED, NOT VERIFIED, or INCONCLUSIVE. **Inconclusive is not a pass.** Do not hide a negative.
- **Gate integrity.** If a worker games the gate (narrows a test pattern, skips a case, loosens an assertion, catches and swallows), reset the unit and harden the contract. If the gate itself is wrong, fix the gate in its own change with its own justification, never route around it mid-unit. This is the operational procedure behind the AGENTS.md rule "Never suppress, skip, ignore, or exclude failures to make checks pass": that rule tells you the outcome is forbidden, and this tells you what to do instead when you hit it.

## Phase D: Keep the audit trail

Keep `ai-output/work/[name]/progress.md` current: a row per decision and per unit, with evidence as paths or commands a reviewer can re-run. Write the row when the unit lands, not at the end. Prefer evidence produced by a checked-in script over a pasted result. The trail plus the diff is what lets the human come back and trust the work.

## Phase E: Verify and hand back

Check the whole against the Phase A predicate with the real chain, not just your harness:

- `bun run test:api <pattern>` and `bun run test:frontend <pattern>`, or `bun test <path>` for one file
- `tsc --noEmit` per affected app
- `bunx biome check --write`
- `bun run test:pw:docker <pattern>` when a user-visible path changed, reading `apps/frontend/test-results/e2e-docker-report.json`
- `bun run --filter frontend test:storybook` and `test:storybook:dark` when a component changed
- `fallow`, which AGENTS.md mandates before finishing, for cycles, duplication, complexity, boundaries, and dead code
- `graphify update .`

Encode any recurring correction as a gate, a lint rule, a test, or a script, so the win cannot silently regress (Call the Skill tool with `principle-encode-lessons-in-structure`).

Leave the tree uncommitted. Report as **Completed / Changed Files / Tests / Blockers**, plus the playbook you designed, the rigor level and why, the `progress.md` path, what is verified against the predicate, and what is still open. Suggest a conventional commit name; do not commit, stage, or stash anything.
