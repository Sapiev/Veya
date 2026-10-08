---
name: principle-make-operations-idempotent
description: Design state-mutating operations to converge on the same end state no matter how many times they run or where a prior run died. Use when writing or reviewing migrations, seeds, key rotation, epoch rollover, or any lifecycle step that can be retried.
disable-model-invocation: true
---

# Make Operations Idempotent

Every state-mutating operation answers two questions before it ships: what happens if this runs twice, and what happens if the previous run crashed halfway. If the answer depends on what the last run left behind, the operation needs an explicit reconciliation step.

Neither AGENTS.md nor the harness prompt asks these questions today. Nothing in our verify rules catches a script that only works on a clean database. Ask them yourself.

**Why:** Retries, restarts, and half-finished runs are normal, not exceptional. When partial state changes the next run's outcome, every crash becomes a debugging session on a state nobody designed and no test covers.

**The three-question test:**

1. What happens if this runs twice in a row?
2. What happens if the previous run crashed at *every* possible point, not just the convenient one?
3. Does re-execution converge to the same end state?

Any "it depends on what was left behind" is a defect.

**Where this bites us:**

- **Drizzle migrations.** `bun run --filter api migration:migrate` must be safe to rerun against a partially migrated database. A migration that assumes a column is absent, or that backfills without a guard, converges only on a virgin schema. `migration:fresh` (`src/console/fresh.ts`) and `db:seed` (`src/console/seed.ts`) get the same treatment: seeding twice produces the seeded state, not doubled rows or a unique-constraint crash.
- **Partial key rotation.** This is the sharp one. Rotation re-seals the closing epoch's log key to every archive recipient, writes the client-lane `epoch.closed` entry, bumps the vault epoch, then writes the server-lane entry under the *new* epoch. A crash between any two of those leaves a vault whose epoch, sealed archive keys, and chain tip disagree. Design the reconciliation before the happy path: on re-run, detect which steps landed and finish the rest, rather than assuming step one has not happened.
- **Epoch rollover.** Same shape. The chain has a defined tip and the vault has a defined epoch; a half-rollover has neither consistently. A rerun must be able to read the current state and drive it forward, not start over and duplicate appends.

**Pattern:** scan for existing state before acting, compare by content rather than by creation order, and make the "already done" branch a normal, tested path rather than an error. Write the crash-midway case as a test: run the operation, kill it after step one, run it again, assert the same end state.
