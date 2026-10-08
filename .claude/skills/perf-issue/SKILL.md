---
name: perf-issue
description: "One-off performance fix driven by a measured baseline and a trace, using eight strategy families strictly as trace-gated hypothesis generators. Use when something specific is slow and the ask is to make it faster, not to hillclimb a metric."
disable-model-invocation: true
---

# Perf issue

You own the measurement story. Every fix ties to a number. Do not read source instead of measuring.

This is the one-off fix. For sustained iterative improvement against a target, call the Skill tool with `hillclimb`. When someone hands you a captured artifact rather than a live surface, call the Skill tool with `trace-forensics` first and come back here once the cause is attributed.

## 1. Capture a baseline

No baseline, no fix. The baseline is a number produced by a repeatable command, sampled enough to clear the noise (median of N runs, not one run).

Call the Skill tool with `benchmark` for the measurement setup, and delegate the harness and the runs to a `performance-benchmarker` subagent when the workload is nontrivial.

Where the number comes from:

| Slow thing | Baseline surface |
| --- | --- |
| A user flow end to end | `bun run test:pw:docker <pattern>`, timings in `apps/frontend/test-results/e2e-docker-report.json` |
| An API route or server module | `bun run test:api <pattern>` around an instrumented call, or a driver script under `ai-output/temp/` |
| Frontend logic below the component | `bun run test:frontend <pattern>` or `bun test <path>` |
| Render cost of a component | `bun run --filter frontend test:storybook` with the profiler attached, or the `browser` tool's performance trace |
| Anything needing a live server, watcher, or long capture | a `hub` supervised process |

Store the artifacts under `ai-output/temp/` and name the paths in the reply.

## 2. Ground the hypotheses in the trace

Call the Skill tool with `how` to learn what the hot path actually does before claiming a ceiling. A perf claim about code you have not run is a guess.

Most fixes come from eight strategy families. **They are hypothesis generators, not a checklist.** A family earns an attempt only when the trace shows the signal that family names. Applying several speculatively is the failure mode: it adds risk, muddies attribution, and usually leaves the dominant cost untouched. A focused fix for the dominant cost beats all eight applied blind.

- **Elimination.** The cheapest work is work that does not run. Before optimizing the hot path, ask whether it needs to exist: a computation nobody consumes, a feature gate always off for this user, a sync that redundantly mirrors state, a legacy path kept "just in case". The trace shows what is slow, never that it is deletable, so this family comes from the `how` pass and from `fallow` dead-code output, not from the profiler. When it applies, it beats every other family.
- **Divide and conquer.** The dominant cost scales with input size. Split the work so each piece touches less (chunk, shard, prune the search space) or so independent pieces run in parallel.
- **Caching.** The same computation or fetch repeats on identical inputs. Store and reuse the result, and name what invalidates it before claiming the win.
- **Indirection.** The hot path does expensive work a cheaper intermediate could absorb: an index instead of a scan, a queue that shifts work off the interactive path, a handle that lets a cheaper implementation swap in. Add the hop only when it removes more from the critical path than it adds. A layer that sits on the hot path without removing work is pure cost.
- **Batching.** Many small operations each pay a fixed overhead (round trip, query, syscall, draw call). Coalesce them so the overhead is paid once per batch.
- **Redundancy.** The wait hangs on one slow instance or attempt. Duplicate the work (replicas, hedged requests, speculative execution) and take the fastest result. This trades load for tail latency, so the trace has to show the wait dominates and the system has headroom. Duplication without that tradeoff only adds load.
- **Lazy evaluation.** Cost lands on results that are never used or not needed yet: eager init on the boot path, rendering offscreen items. Defer until first use.
- **Scheduling.** The work must happen, but not during the interactive moment. Move it to where nobody is waiting: idle callbacks, a background warmup after boot, precompute before the user arrives, cleanup after the frame commits. Distinct from lazy evaluation, which runs the work later when needed; scheduling often runs it *earlier*, or in the shadow of something else. The win is perceived latency, so measure the interactive path, not total work done.

Write down which family the trace justifies and the signal that justifies it. If you cannot name the signal, you do not have a hypothesis yet; go back to the trace.

## 3. One attempt at a time

If the fix crosses a function boundary, design it first with a `backend-architect` or `frontend-developer` subagent. Delegate implementation with a tight scope and review the diff.

Verify each attempt before starting the next. That is `principle-sequence-verifiable-units`: no second change rides on an unmeasured first one. Capture a post-fix trace with the same command that produced the baseline. Changing the harness between runs invalidates the comparison.

Correctness gates the win. Run the tests covering the touched code (`bun run test:api`, `bun run test:frontend`, or `bun run test:pw:docker` as appropriate) plus `tsc --noEmit` and `bunx biome check --write`. A faster wrong answer is not a fix, and a failing check is never suppressed to land a number.

## 4. Compare the artifacts, do not eyeball them

Load both traces and diff them rather than reading them. The `eval` kernel plus sqlite is the tool for this; `trace-forensics` has the load-and-query loop. Report the delta as a number with its sampling method.

"Inconclusive" is not a pass. A win measured on a different surface than the complaint is not a pass. Flag either instead of shipping it.

## 5. Revert what the numbers do not support

Any change the post-fix trace does not justify comes back out, including the tidy-ups you made along the way. The smallest change the measurement justifies ships, nothing more.

## Finish

Leave the tree uncommitted. Report as:

- **Completed**: baseline number, post-fix number, delta with sampling method, the family the trace justified and the signal that justified it, artifact paths under `ai-output/temp/`.
- **Changed Files**
- **Tests**: the correctness gate, green.
- **Blockers**

Suggest a conventional commit name that carries the number, for example `perf(audit): batch chain checkpoint reads, 840ms to 190ms p50`. Log the outcome in `ai-output/work/[name]/progress.md`.
