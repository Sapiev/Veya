---
name: hillclimb
description: "Iterative loop that drives one measured metric toward a target: freeze a harness and prove it can detect a known regression, then one hypothesis per iteration, keep or revert, logged. Use for 'hillclimb on X', 'make X 50% faster', 'keep trying until <metric> improves by N%'."
disable-model-invocation: true
---

# Hillclimb

You own the metric and the integrity of the experiment. Supervise and review; delegate the attempts.

For sustained improvement of one measurable thing against a target: "hillclimb on X", "make startup 50% faster", "systematically drive down <metric>", "keep trying until <metric> improves by N%". A one-off fix is not this; call the Skill tool with `perf-issue` or `bug-fix` for those. This is the loop.

This is the natural partner of the `benchmark` skill. Call the Skill tool with `benchmark` to build and calibrate the measurement itself; this skill governs what you do with it once it exists.

**Core discipline: one change, one measurement, keep or revert.** Never stack untested changes. Never claim a win from code inspection. The data decides.

## 1. Ground the workload before choosing the ruler

Call the Skill tool with `how` over the target. Name the realistic workload dimensions that can move the result: data size, history depth, stored state, concurrency, cold versus warm. Select a case that reproduces the actual complaint. If no case reproduces it, fix the reproduction first; there is nothing to climb yet.

Then fix three things in writing:

- One metric and the direction that counts as better.
- A stop predicate that pairs a target with a floor on attempts, so a lucky early win cannot end the run. "At least 50% better than baseline and at least 10 iterations" is the shape.
- The regression gate: the exact test commands that must stay green for a change to count as accepted.

Use the user's numbers when given; otherwise agree them before starting.

## 2. Build the harness, prove its sensitivity, then freeze it

The harness is the lever the whole run rests on, so build it properly: `principle-build-the-lever` applies directly. One repeatable command emits the metric.

**Prove sensitivity before you trust it.** A harness that cannot detect a known regression cannot validate an improvement. Run contrasting realistic workloads and confirm the target case reproduces the symptom while easier cases separate as expected. Better, inject a deliberate slowdown or a known-bad input and confirm the harness reports it. If the ruler cannot distinguish cases you know differ, revise the workload or the metric before continuing.

Sample enough to clear the noise: median of N runs, with the spread recorded, never a single run.

Once proven, freeze it. Changing the harness mid-run invalidates every earlier number. If you must change it, re-baseline and say so explicitly in the log.

Record two things before any change: the baseline metric, and a green run of the regression gate.

Surfaces available for the harness:

| Metric lives in | Command |
| --- | --- |
| A user flow end to end | `bun run test:pw:docker <pattern>`, timings in `apps/frontend/test-results/e2e-docker-report.json` |
| API or server code | `bun run test:api <pattern>`, or a driver script under `ai-output/temp/` |
| Frontend logic | `bun run test:frontend <pattern>` or `bun test <path>` |
| Component render | `bun run --filter frontend test:storybook` and `test:storybook:dark` |
| Anything needing a live server or a long capture | a `hub` supervised process |

Delegate the harness build and the repeated runs to a `performance-benchmarker` subagent.

## 3. Open the decision log

The log is the run's memory. Without it the search circles instead of accumulating.

Keep it in `ai-output/work/[name]/progress.md` as a table, **one row per iteration**, written whether the attempt was kept or reverted:

| id | hypothesis | change | before | after | delta | gate | verdict | note |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | epoch index is scanned per row, so batch the lookup | `apps/api/src/audit/chain.ts` | 840ms | 190ms | -77% | green | kept | dominant cost, confirmed in trace |
| 2 | memoize receipt verification | `apps/api/src/receipts/verify.ts` | 190ms | 188ms | -1% | green | reverted | inside noise |

Read the log before each attempt. A reverted row is as valuable as a kept one: it is the record of a branch already searched.

## 4. Ground each hypothesis in a mechanism

Every hypothesis names a specific mechanism from the model in step 1: "defer the key derivation off the boot path because it blocks first paint". Not "try memoizing something". A hypothesis you cannot state mechanistically cannot be refuted by a measurement, only rationalized.

For the catalogue of mechanism families and the rule that a family earns an attempt only when the measurement shows its signal, call the Skill tool with `perf-issue`.

## 5. Loop, one hypothesis per iteration

For each iteration:

1. Hand the change to a subagent with a tight scope. Supervise and review the diff rather than typing it; your own context is the scarce resource across a long run. When several independent hypotheses are live, fan them to parallel subagents, each writing to a distinct set of files and its own scratch directory under `ai-output/temp/`, so their edits cannot collide. That separation is `principle-separate-before-serializing-shared-state` applied to the run itself: keep the attempts apart, then serialize the accepted one into the tree.
2. Measure before and after with the frozen harness.
3. Run the regression gate.
4. Accept only when the metric moves past noise **and** the gate stays green. Otherwise revert the change in full. A tweak that "might help" does not ride along on an accepted change.
5. Write the row either way.

Each iteration ends in a check before the next begins: `principle-sequence-verifiable-units`. Nothing is committed at any point; accepted changes accumulate in the working tree and the log is what records their order.

## Blinding, when the metric is a judgement

If what you are climbing is agent or prompt behavior rather than a wall-clock number, the observer effect is the dominant error source and an unblinded judgement will confirm whatever you hoped. Hold these:

- No `eval`, `test`, `judge`, `experiment`, `rubric`, `score`, `compare`, `benchmark`, `candidate`, or `arena` in any directory, file, or prompt the subject sees.
- The prompt reads like an organic request. State the goal, not the meta: "build me a small todo cli", not "show me how you follow the rules".
- No chain-eliciting cues. Do not ask the subject which skills or files it applied; that inflates citation behavior. Ask for design notes generally and grade from the output's shape, not from self-report.
- Sanitize directory and slug names. Use project-shaped names, not `candidate-1` or `variant-a`.
- Do not tell the subject that a comparison exists.
- The judge may know it is judging, but sees outputs by sanitized label only. Score both variants in a single pass on one scale; two judge runs with different prompts do not compare, because the calibration drifts between them.
- Verify behavior from the artifacts produced, never from the subject's own claims about what it did.

## 6. Push past the first plateau

On a stall, several rejects in a row: pivot category, combine near-misses, re-read the source, or try something more radical before concluding the hill is climbed.

Correctness and simplicity outrank the number. Revert a win that breaks behavior. Keep a simplification that holds the number.

## 7. Stop honestly

Stop when the predicate is met, or when the remaining ideas are genuinely marginal and not worth their cost. Do not relax the predicate to declare victory. Do not quit while cheap untried hypotheses remain. If you are stuck, surface it instead of spinning.

## Finish

Leave the tree uncommitted. Report as:

- **Completed**: the metric and target, baseline to final with the percent delta, iterations run (kept versus reverted), each accepted change on one line, the path to the log in `ai-output/work/[name]/progress.md`, and the best idea you would try next if pushed further.
- **Changed Files**
- **Tests**: the regression gate, green, plus the harness command and its sampling method.
- **Blockers**

Suggest one conventional commit name per accepted change, in the order they landed, so the climb reads top to bottom.
