---
name: diagnosing-bugs
description: Diagnosis loop for hard bugs and performance regressions. Use when the user says "diagnose"/"debug this", or reports something broken/throwing/failing/slow.
---

# Diagnosing Bugs

A discipline for hard bugs. Skip phases only when explicitly justified.

Orient before you explore: `AGENTS.md` for the rules, `fallow` for the shape of the module you are entering, and any prior `ai-output/work/[name]/progress.md` covering this area for what was already tried.

## Redact

This skill has you show commands, outputs and captured artifacts. **Redact every secret first**: write `<REDACTED>` in its place. Build loops against env vars, so the credential stays in the environment rather than in what you show. Captured artifacts carry auth headers: quote only the lines that carry the signal.

This is a zero-knowledge vault, so the bar is higher than "no API keys in the log". A debug log must never carry plaintext vault content, a key or key share of any kind, a token, or a receipt byte string. Log the shape, the length, and the hash prefix; never the bytes. A `[DEBUG-...]` line that dumps a signed payload has moved a secret from an encrypted column into your terminal scrollback, your captured artifact, and your writeup.

If the redacted output is not enough to diagnose the bug, say so and ask the user.

## Phase 1: Build a feedback loop

**This is the skill.** Everything else is mechanical. If you have a **tight** pass/fail signal for the bug (one that goes red on _this_ bug), you will find the cause; bisection, hypothesis-testing, and instrumentation all just consume it. If you don't have one, no amount of staring at code will save you.

Spend disproportionate effort here. **Be aggressive. Be creative. Refuse to give up.**

### Ways to construct one, in roughly this order

1. **Failing test** at whatever seam reaches the bug: unit, integration, e2e.
2. **HTTP script** against a running dev server, started as a supervised process with `hub` so it survives across calls and its logs stay readable.
3. **CLI invocation** with a fixture input, diffing stdout against a known-good snapshot.
4. **Headless browser script** with the `browser` tool that drives the UI and asserts on DOM, console, and network.
5. **Replay a captured trace.** Save a real network request, payload, or event log to `ai-output/temp/`; replay it through the code path in isolation.
6. **Throwaway harness.** Spin up a minimal subset of the system (one service, mocked deps) that exercises the bug code path with a single function call. The `eval` kernel is the cheapest version of this: state persists across cells, so you can build the input once and re-run the suspect call a hundred times.
7. **Property / fuzz loop.** If the bug is "sometimes wrong output", run 1000 random inputs and look for the failure mode.
8. **Bisection harness.** If the bug appeared between two known states, automate "set state X, check, repeat". Bisect over inputs, config, dataset, or a pinned dependency version freely. A bisect over a commit range moves the working tree, so ask the user before starting one.
9. **Differential loop.** Run the same input through two versions or two configs and diff outputs. This is the natural loop for a parity bug: the same receipt through `lib/receipt.ts` and through `scripts/verify-receipt.mjs`.
10. **HITL bash script.** Last resort. If a human must click, drive _them_ with [`scripts/hitl-loop.template.sh`](scripts/hitl-loop.template.sh) in this skill's directory, so the loop is still structured. Captured output feeds back to you.

Build the right feedback loop, and the bug is 90% fixed.

### The loop commands here

Retarget every loop at a real command in this repo:

- `bun test <path>` for one file. The tightest loop available; prefer it.
- `bun run test:api <pattern>` for api unit and integration tests.
- `bun run test:frontend <pattern>` for frontend unit tests.
- `bun run test:pw:docker <pattern>` for Playwright e2e in Docker. Slowest, so narrow the pattern hard. The machine-readable signal is the report at `apps/frontend/test-results/e2e-docker-report.json`: read that rather than scraping terminal output, because it is the only form of the result you can assert on and diff across runs.
- `bun run --filter frontend test:storybook` and `test:storybook:dark` for component-level visual behaviour.
- `tsc --noEmit` per app when the symptom is a type-level break rather than a runtime one.

**Intermittent e2e failures are the canonical case for the non-determinism doctrine below.** A Playwright-in-Docker spec that fails one run in twenty is not a flake to be retried; it is a real bug at a 5% reproduction rate, and the job is to raise that rate.

### Tighten the loop

Treat the loop as a product. Once you have _a_ loop, **tighten** it:

- Can I make it faster? (Cache setup, skip unrelated init, narrow the test scope.)
- Can I make the signal sharper? (Assert on the specific symptom, not "didn't crash".)
- Can I make it more deterministic? (Pin time, seed RNG, isolate filesystem, freeze network.)

A 30-second flaky loop is barely better than no loop; a 2-second deterministic one is tight, a debugging superpower.

### Non-deterministic bugs

The goal is not a clean repro but a **higher reproduction rate**. Loop the trigger 100 times, parallelise, add stress, narrow timing windows, inject sleeps. A 50%-flake bug is debuggable; 1% is not, so keep raising the rate until it's debuggable. A looping reproduction is a supervised `hub` process: start it, let it run, read its logs, rather than re-invoking it by hand.

### When you genuinely cannot build a loop

Stop and say so explicitly. List what you tried. Ask the user for: (a) access to whatever environment reproduces it, (b) a redacted captured artifact (HAR file, log dump, core dump, screen recording with timestamps), or (c) permission to add temporary instrumentation. Do **not** proceed to hypothesise without a loop.

### Completion criterion: a tight loop that goes red

Phase 1 is done when the loop is **tight** and **red-capable**: you can name **one command** (a script path, a test invocation, an HTTP call) that you have **already run at least once** (show the invocation and its output, redacted), and that is:

- [ ] **Red-capable**: it drives the actual bug code path and asserts the **user's exact symptom**, so it can go red on this bug and green once fixed. Not "runs without erroring"; it must be able to _catch this specific bug_.
- [ ] **Deterministic**: same verdict every run (flaky bugs: a pinned, high reproduction rate, per above).
- [ ] **Fast**: seconds, not minutes.
- [ ] **Agent-runnable**: you can run it unattended; a human in the loop only via this skill's [`scripts/hitl-loop.template.sh`](scripts/hitl-loop.template.sh).

If you catch yourself reading code to build a theory before this command exists, **stop: jumping straight to a hypothesis is the exact failure this skill prevents.** No red-capable command, no Phase 2.

## Phase 2: Reproduce + minimise

Run the loop. Watch it go red as the bug appears.

Confirm:

- [ ] The loop produces the failure mode the **user** described, not a different failure that happens to be nearby. Wrong bug = wrong fix.
- [ ] The failure is reproducible across multiple runs (or, for non-deterministic bugs, reproducible at a high enough rate to debug against).
- [ ] You have captured the exact symptom (error message, wrong output, slow timing) so later phases can verify the fix actually addresses it.

### Minimise

Once it's red, shrink the repro to the **smallest scenario that still goes red**. Cut inputs, callers, config, data, and steps **one at a time**, re-running the loop after each cut, and keep only what's load-bearing for the failure.

Why bother: a minimal repro shrinks the hypothesis space in Phase 3 (fewer moving parts left to suspect) and becomes the clean regression test in Phase 5.

Done when **every remaining element is load-bearing**: removing any one of them makes the loop go green.

Do not proceed until you have reproduced **and** minimised.

## Phase 3: Hypothesise

Generate **3-5 ranked hypotheses** before testing any of them. Single-hypothesis generation anchors on the first plausible idea.

Each hypothesis must be **falsifiable**: state the prediction it makes.

> Format: "If <X> is the cause, then <changing Y> will make the bug disappear / <changing Z> will make it worse."

If you cannot state the prediction, the hypothesis is a vibe: discard or sharpen it.

**Show the ranked list to the user before testing.** They often have domain knowledge that re-ranks instantly ("we just deployed a change to #3"), or know hypotheses they've already ruled out. Cheap checkpoint, big time saver. Don't block on it; proceed with your ranking if the user is AFK.

## Phase 4: Instrument

Each probe must map to a specific prediction from Phase 3. **Change one variable at a time.**

Tool preference, strongest first:

1. **The `debug` tool.** A DAP session against the real process: set a breakpoint at the line the hypothesis names, then read the actual variables, the stack, and the scopes. One breakpoint beats ten logs, and this is the tool that gives you one.
2. **The `eval` kernel** for a scratch hypothesis. Persistent state across cells, so you can hold the suspect input, call the function directly, and vary one argument at a time without a rebuild.
3. **`hub` supervised processes** when the probe needs something alive: a dev server whose logs you read at intervals, or a reproduction looping in the background while you work.
4. **The `browser` tool** when the symptom is in the UI. Drive the real page, then assert on DOM, console, and network rather than inferring from a screenshot.
5. **Targeted logs** at the boundaries that distinguish hypotheses.
6. Never "log everything and grep".

**Tag every debug log** with a unique prefix, e.g. `[DEBUG-a4f2]`. Cleanup at the end becomes a single grep. Untagged logs survive; tagged logs die.

**Perf branch.** For performance regressions, logs are usually wrong. Instead: establish a baseline measurement (timing harness, `performance.now()`, profiler, query plan), then bisect. Measure first, fix second.

## Phase 5: Fix + regression test

Write the regression test **before the fix**, but only if there is a **correct seam** for it.

A correct seam is one where the test exercises the **real bug pattern** as it occurs at the call site. If the only available seam is too shallow (single-caller test when the bug needs multiple callers, unit test that can't replicate the chain that triggered the bug), a regression test there gives false confidence.

**If no correct seam exists, that itself is the finding.** Note it. The codebase architecture is preventing the bug from being locked down. Flag this for the next phase.

If a correct seam exists:

1. Turn the minimised repro into a failing test at that seam.
2. Watch it fail.
3. Apply the fix.
4. Watch it pass.
5. Re-run the Phase 1 feedback loop against the original (un-minimised) scenario.

## Phase 6: Cleanup

Required before declaring done:

- [ ] Original repro no longer reproduces (re-run the Phase 1 loop)
- [ ] Regression test passes (or absence of seam is documented)
- [ ] All `[DEBUG-...]` instrumentation removed (`grep` the prefix)
- [ ] Throwaway prototypes deleted, or moved under `ai-output/temp/`
- [ ] `bunx biome check --write`, then `tsc --noEmit` for each app you touched
- [ ] The tree is left uncommitted. Report as Completed / Changed Files / Tests / Blockers, and suggest a conventional-commit name.
- [ ] **The hypothesis that turned out correct is written into `ai-output/work/[name]/progress.md`**, with the loop command that caught it, so the next debugger inherits the loop rather than rebuilding it. This entry is the deliverable, not a courtesy.
