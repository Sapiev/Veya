---
name: interrogate
description: "Adversarially review a change in two named passes, then filter the findings as lead reviewer so the user gets a short actionable verdict instead of a wall of nits. Use for \"interrogate this\", \"adversarial review\", \"challenge this\", \"stress test this code\", \"find blind spots\", or \"tear this apart\"."
disable-model-invocation: true
---

# Interrogate

Adversarial review of a change, followed by hard filtering. The deliverable is a synthesized verdict. Never auto-apply the findings.

The value of this skill is the triage discipline in Step 5, not the fan-out in Step 3. A review that hands back every finding a reviewer produced has done nothing a reviewer could not do alone.

## Two named passes, not a model panel

Run exactly two passes:

| Pass | Subagent | Lens |
|------|----------|------|
| Correctness and quality | `reviewer` | bugs, design flaws, maintainability, the code-quality lens below |
| Security | `security-reviewer` | evidence-backed vulnerability discovery, crypto and auth invariants, data exposure |

The upstream version of this skill spawned one reviewer per configured model and justified it with model diversity: different families have different blind spots, so agreement across families is real signal. We run one model family. Four same-family passes buy correlated blind spots at four times the tokens, against a repo whose first rule is token efficiency. Two passes with genuinely different lenses beat four passes with the same one. Do not re-inflate this to a model panel.

## Reviewers do not re-derive what tooling already answers

`fallow` mechanically reports dead code, duplication, import cycles, complexity hotspots and architecture-boundary violations, and AGENTS.md mandates a `fallow` pass before finishing anyway. A reviewer spending its pass hand-computing those is wasting the pass. Run `fallow` yourself, put its output in the packet as established fact, and tell both reviewers to spend their attention on what static analysis cannot see: whether the code does what it claims, on real inputs, on reachable paths.

Same for the security pass: it exists to find reachable vulnerabilities in this diff, not to restate a checklist. If you want the checklist walked instead, that is a different job. Call the Skill tool with `security-review`.

## Step 1, Determine scope

Identify what to review:

- The user points at files or a diff, use that.
- On a feature branch, `git diff main...HEAD` for the full changeset.
- The user's message references recent work, gather those files with `grep` and `glob`.

Package the diff plus the surrounding context a reviewer needs to trace a call site: the callers, the types at the boundary, the tests that already cover it. Reviewers that cannot see the call chain invent hypotheticals, and you will spend Step 5 dismissing them.

## Step 2, State the intent

Write one clear paragraph on what this code is trying to accomplish, derived from the user's message, the commit messages, `pr://<N>` or `issue://<N>` if either exists, and the code itself.

Reviewers challenge whether the work achieves the intent well, not whether the intent is correct. If you are unsure of the intent, ask before spawning anything.

## Step 3, Run the two passes

Spawn both in a single `task` batch so they run concurrently. Both get the same packet: the intent, the diff and context, the `fallow` output as established fact, and their own brief.

### Shared reviewer brief

> You are an adversarial reviewer. Find real problems: bugs, design flaws, security issues, maintainability risks. You are not here to be encouraging. You are here to stress-test.
>
> The author's stated intent is `{INTENT}`. Review whether the code achieves it. Do not question the intent itself.
>
> Static analysis has already run and its output is attached. Do not spend your pass re-deriving dead code, duplication, cycles, complexity or boundary violations. Spend it on what static analysis cannot see.
>
> For each finding give:
> 1. **Severity**: `critical` (bugs, data loss, security, broken behaviour) | `warning` (design or correctness risk that will cause pain) | `nit` (style, naming; only if genuinely useful, never to pad).
> 2. **Finding**: the concrete problem, at a specific `file:line` or function.
> 3. **Evidence**: why you believe it. Show the reasoning. Do not assert.
> 4. **Suggestion**: optional, only when you have a concrete alternative.
>
> A good finding references specific code, explains why it is a problem, distinguishes "this is broken" from "I would have done this differently", and accounts for the stated intent. Do not restate what the code does, do not suggest rewrites of working code on style preference, do not raise a hypothetical without showing the path is reachable, do not praise the code. Zero findings is a valid outcome: say "no findings" and stop.
>
> Do not edit anything. Read only.

### Code-quality lens for the `reviewer` pass

Add these four dimensions. Apply the ones that are relevant; do not force a lens that does not apply.

1. **No spaghetti growth in existing code.** Be suspicious of new ad-hoc conditionals, scattered special cases, or one-off branches inserted into unrelated flows. Treat a weird `if` in a random place as a design problem, not a style nit. Prefer pushing the logic into a dedicated helper, state machine, or module over tangling an existing path.
2. **Direct and boring over hacky or magical.** Treat brittle, ad-hoc or magic behaviour as a problem. Be skeptical of generic mechanisms that hide simple data-shape assumptions. Flag thin abstractions, identity wrappers and pass-through helpers that add indirection without buying clarity.
3. **Type and boundary cleanliness where it affects maintainability.** Question unnecessary optionality, `unknown`, `any`, and cast-heavy code when a clearer type boundary could exist. Prefer explicit typed models over loosely shaped ad-hoc objects. If a branch leans on a silent fallback to paper over an unclear invariant, ask whether the boundary should be explicit instead.
4. **Logic stays in the canonical layer, and existing helpers get reused.** Call out feature logic leaking into shared paths and implementation details leaking through APIs. Prefer an existing canonical utility over a bespoke one-off. Push code toward the right package, service or module instead of normalizing drift.

Two things the upstream lens demanded that do not apply here:

- **No line-count threshold.** Upstream treated pushing a file past 1000 lines as a presumptive blocker. File length is not a defect and splitting a file to satisfy a number is churn with a diff attached.
- **No "be ambitious, restructure the codebase" framing.** AGENTS.md orders correctness > reuse existing code > context efficiency, and ranks new abstractions last. Speculative restructuring of crypto or audit-log code during a review is the wrong instinct: the review is there to find what is wrong with the change, not to widen it. A restructuring that removes real complexity is a legitimate finding. "This could be architected differently" is not.

## Step 4, Synthesize

1. Parse all findings from both passes.
2. Note where the two passes independently landed on the same issue. That is your strongest signal, because they came at it through different lenses.
3. Deduplicate. Merge findings that describe one issue and note which pass raised it.
4. Note disagreements. One pass flagging what the other explicitly cleared is useful context for the verdict.

Two passes give you far less consensus signal than a four-model panel did, so do not lean on vote counting. A single-pass finding with a traced execution path outranks agreement between two vague ones.

## Step 5, Lead judgment

You are the lead reviewer, a pragmatic senior engineer, not a neutral aggregator. Read `references/lead-judgment.md` and apply it. Reviewers saw a slice of the codebase and a one-paragraph intent. You have the full context: the goal, the constraints, what was already tried and rejected, which code is scaffolding and which is permanent. Use it aggressively.

Categorize every finding:

- **Act on**. Real issues in correctness, security or maintainability given the actual goals. These would block a real review.
- **Consider**. Legitimate, but you are not sure the fix outweighs its cost right now. Worth the user's attention.
- **Noted**. Technically valid, not actionable. Context-dependent, premature, or low impact at this stage.
- **Dismissed**. Wrong, nitpicky, or missing context. Brief reason why.

For each finding record which pass raised it, the category, and a one-line rationale.

## Output format

### Intent
> The stated intent paragraph from Step 2.

### Passes
- `reviewer`: N findings
- `security-reviewer`: N findings

### Act On
Findings that should be addressed. For each: description, which pass raised it, why it matters. Over five items here means you did not filter hard enough.

### Consider
Findings worth thinking about. For each: description, which pass, the tradeoff.

### Noted
Valid but low priority. Brief list.

### Dismissed
Rejected findings with a one-line rationale each. This is a trust mechanism, not busywork: it lets the user override you where they disagree.

### Where the passes diverged
Where the correctness lens and the security lens reached different conclusions, and what that difference tells you about the change.

## Finishing

Leave the tree uncommitted. Report as Completed / Changed Files / Tests / Blockers, suggest a conventional-commit name for any fix the user then asks for, and log the verdict in `ai-output/work/[name]/progress.md`.
