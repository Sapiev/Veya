---
name: principle-encode-lessons-in-structure
description: Turn a correction you have now made twice into the strongest available mechanism (type, lint, check, helper, guard) and delete the prose it replaces. Use when you notice a recurring fix, or catch yourself writing the same instruction a second time.
disable-model-invocation: true
---

# Encode Lessons in Structure

Prose asks the reader to notice, remember, and comply. A mechanism does not ask. When you have corrected the same thing twice, stop writing it down and encode it.

**Why:** Instructions are easy to miss and easy to outvote. Agents copy whatever the surrounding code already does, so a weak guard becomes the next template. AGENTS.md is our weakest rung and our current default, which is why the same corrections keep coming back.

**Trigger:** you have now corrected the same thing twice. Not once. Twice.

**Pick the strongest rung.** In descending strength, take the strongest the situation allows:

1. **A type that makes the mistake unrepresentable.** Best outcome: the wrong code does not compile. Discriminated unions over optional-field soup, branded ids, exhaustive variant handling, `unknown` at boundaries. Caught by `tsc --noEmit`, on every run, for free.
2. **A Biome rule or a `fallow` check.** Mechanical and repo-wide. `bunx biome check --write` for style and banned APIs; `fallow` for dead code, duplication, cycles, complexity, and architecture boundaries. Fails without cooperation.
3. **A shared helper.** One canonical implementation people reach for instead of rewriting the hazard. `apps/frontend/lib/testing/mockModule.ts` is the model: the lesson about Bun's process-wide module registry lives in a function, not in a warning someone had to read. Put these in `packages/` or `apps/api/src/test-support/`.
4. **A runtime guard.** A throw at the boundary with a message that names the fix. Weaker, because it fires only on the path that runs, but real.
5. **Prose in AGENTS.md.** Weakest. Reserve it for things that genuinely need judgement, and when you use it, include the failure mode, not just the rule.

**Corollary:** do not paper over. If the fix is structural, use *only* the structural fix and delete the instruction it replaces. The instruction was the symptom.

**Close the loop:**

- One-off: note it in `ai-output/work/[name]/progress.md` and move on.
- Recurring: climb the ladder above, apply now, and delete the prose in the same change.
- Systemic: it is a principle, not a rule. Say so.

**Anti-patterns:** acknowledging without recording; recording a rung-2 idea in `progress.md` and never building it; fixing the one instance and leaving the pattern intact.
