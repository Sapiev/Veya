---
name: principle-sequence-verifiable-units
description: Break multi-step work into units that each end in a check, and take each unit red to green before starting the next. Use for sweeps, migrations, refactors, or any run of similar edits.
disable-model-invocation: true
---

# Sequence Work into Verifiable Units

Order the work as small units, each ending in a state you can check, and do not advance until the current one is green.

**Why:** A break caught at the unit that caused it is cheap to localize. A break caught after a twelve-file batch is buried, and you have already built further on a broken base. Bisecting your own uncommitted sweep is the most expensive way to find a typo.

**Pattern:**

- Pick the smallest unit that ends in a check: one edit plus the test that covers it.
- Bracket it. Known-good state, one change, run the check, proceed.
- Never batch the edits and verify once at the end. That is the failure mode this principle exists to stop.
- When a lever does the edits, the per-unit check is nearly free. Run it anyway.

**The per-unit checks, because they are fast enough to run per unit:**

- `bun test <path>` on the single file that covers the change. Not `bun run test:api` across the suite, not `turbo run test`. One file, seconds.
- `tsc --noEmit` in the app you touched, when the unit changes a type or a signature. Fast enough to run between units and the only thing that catches a break three files away.

Save the wide runs for the end: `bun run test:api <pattern>`, `bun run test:frontend <pattern>`, `bun run test:pw:docker <pattern>`, `turbo run check-types`, `fallow`. Those confirm the whole sweep. They are not the per-unit check, and using them as one is how the loop gets abandoned.

**Test:** if you cannot name the check that closed the last unit, you are batching.

Pairs with `principle-build-the-lever`, which makes the per-unit check cheap enough that there is no excuse to skip it. Call the Skill tool with `principle-build-the-lever` when the units are mechanical.
