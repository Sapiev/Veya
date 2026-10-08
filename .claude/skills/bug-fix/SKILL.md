---
name: bug-fix
description: "Ordinary bug-fix loop: reproduce on the real surface yourself, binary-search the cause with runtime evidence, and land the failing test before the fix. Use when asked to fix a specific reported bug whose surface you can reach."
disable-model-invocation: true
---

# Bug fix

The ordinary case: one bug, a reachable surface, and a fix no larger than the evidence justifies.

For a genuinely hard bug (no stable reproduction, a heisenbug, a regression whose cause spans subsystems), call the Skill tool with `diagnosing-bugs`. That is the deeper six-phase discipline; this playbook does not duplicate it. Come back here once the surface is reachable.

## The rule

Be scientific. Every shipped line traces to runtime evidence. A belt-and-suspenders change that "might help" is a hypothesis, not a fix, and it does not ship. When evidence refutes a hypothesis, revert what it motivated. The smallest change the evidence justifies ships, nothing more.

## Verification surfaces

Pick the surface the bug actually lives on. There is no generic one.

| Bug lives in | Drive it with |
| --- | --- |
| A full user flow | `bun run test:pw:docker <pattern>`, machine-readable report at `apps/frontend/test-results/e2e-docker-report.json` |
| A React component | `bun run --filter frontend test:storybook`, plus `test:storybook:dark` when theming is involved |
| A page you need to poke by hand | the `browser` tool |
| An API route or server module | `bun run test:api <pattern>` |
| Frontend logic below the component | `bun run test:frontend <pattern>` |
| One known file | `bun test <path>` |
| State you cannot infer from output | the `debug` tool: breakpoint, step, inspect frames |
| A dev server, watcher, or long capture | a `hub` supervised process, never a backgrounded shell |

## 1. Reproduce it yourself

Drive the surface. Do not hand the reproduction back to the user. If some instrumentation protocol tells you to ask the user to try it, that does not override this: you drive the instrumented runtime. Ask the user only with a stated, specific reason the surface cannot reach the target, and only after driving it as far as it goes.

If it will not reproduce directly, force it: synthesize the trigger, tighten the conditions, or instrument until it fires. A bug you cannot reproduce is a bug you cannot prove fixed.

## 2. Binary-search the cause

List the candidate hypotheses, then eliminate until one survives.

- Seed the list. Call the Skill tool with `how` to learn how the affected subsystem actually works, and with `why` for the history behind the code that looks wrong. Fan both out as parallel `scout` subagents when the subsystem is unfamiliar.
- Each pass, take the split that cuts the most remaining problem space, get runtime evidence, eliminate. Do not sample randomly.
- When program state is unclear, add instrumentation or set a `debug` breakpoint and read state as the code runs. Do not guess.
- Confirm the surviving *mechanism* with runtime evidence before you design anything. A design built on a plausible but unconfirmed cause can be entirely self-consistent and still wrong, with the real cause sitting one subsystem over.

A stubborn hunt is still this loop. Keep splitting; do not switch to reading source and speculating because the evidence is slow to collect.

## 3. Plan the fix

If the fix crosses a function boundary, design it before writing it: a `backend-architect` or `frontend-developer` subagent for the shape, then a scoped implementation task with file paths and the behavior to hold. Review the diff yourself.

When the fix lands on a symbol with many callers, call the Skill tool with `blast-radius` before editing.

## 4. The failing test lands first

Write the reproduction as a test before the fix, so the diff tells the story. The failing test goes into the working tree first, uncommitted, and stays there while you make it pass. That ordering is the canonical shape of `principle-sequence-verifiable-units`: a verifiable unit, then the change that satisfies it.

Call the Skill tool with `tdd` for the failing-test-first cadence. Skip the test only when it would be genuinely expensive or integration-heavy out of proportion to the bug, and say so in the reply rather than silently omitting it.

## 5. Verify on the same surface

Re-run the original reproduction on the surface from step 1.

- "Inconclusive" is not a pass.
- A pass on a different surface is not a pass. A unit test shows branch behavior, not bug absence, so a flow bug needs the e2e run as proof.
- Never edit the assertion, skip the case, or loosen a matcher to get green. That is suppressing a failure, which AGENTS.md forbids outright.

Then `tsc --noEmit` for the touched app, `bunx biome check --write`, and `fallow` before you finish.

## Finish

Leave the tree uncommitted. Report as:

- **Completed**: what was broken, the root cause, the fix.
- **Changed Files**
- **Tests**: the failing-then-passing reproduction output, pasted verbatim.
- **Blockers**

Suggest a conventional commit name that mentions the reproduction, for example `fix(receipts): reject unsigned revocation rows, with failing repro test`. Log the outcome in `ai-output/work/[name]/progress.md`.
