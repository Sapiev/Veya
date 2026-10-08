---
name: why
description: Investigates the motivation behind code, from git history and the review record, and reports it with explicit confidence tiers and named gaps. Use for "why does X work this way", "why did we pick Y", design rationale before changing a security or crypto invariant, regression archaeology, or where a magic threshold came from. Use the how skill for runtime behavior.
---

# Why

Investigate the motivation and intent behind code. Why was it built this way? What edge cases were considered? What constraint shaped the design? What alternatives were rejected?

Companion to the `how` skill. `how` answers what the code does. `why` answers what forces led to its shape.

**The load-bearing rule: the code is not evidence for its own intent.** "It dual-signs because there are two signatures" is mechanics, not motivation. In a zero-knowledge, crypto-heavy codebase a confidently retrofitted rationale is actively dangerous: it becomes the justification for changing an invariant nobody understood. An honest "we could not find out why" is the more useful answer.

## Operating Posture

Operate as a careful, cautious, precise investigator. Think like a detective piecing together a historical case from fragmentary records. When the record is thin, say so.

- **Evidence before narrative.** Collect the pieces first, then see what story they support. Never pick a story and recruit the evidence that fits it.
- **Precision over polish.** Prefer the exact quote and citation over a smooth paraphrase. A reader should be able to follow any claim back to its source and verify it in under a minute.
- **Consider what you have not seen.** The evidence you find is a sample. Before concluding, ask what you would expect to see if an alternative explanation were true, and whether you looked for it.
- **Name the gaps.** If a thread goes cold or a source is not searchable, document the gap. Do not paper it over with an authoritative-sounding guess.
- **Hedge on purpose.** When evidence is indirect, the language must signal it ("appears to", "likely", "suggests"). Confidence-matching phrasing is part of the output, not a stylistic choice.
- **No shortcut by code-reading.** Resist inferring intent from code shape.

Read `references/epistemics.md` for the confidence tiers, the phrasing guide, and the calibration check. It is mandatory, not background reading.

## Step 1. Understand the target and the question

The **target** is usually a chunk of code, a pattern, a constant, or a named design decision. The **question** is usually one of:

- "Why was X designed this way?" Design rationale.
- "Why do we do X instead of Y?" Tradeoff or alternatives.
- "What edge cases motivated this?" Defensive reasoning.
- "Where did this threshold come from?" Magic number archaeology.
- "Why does this code still exist?" Dead code territory.

If the target is vague, make your best guess from conversation context (files just read, recent edits, what was just discussed). State your interpretation briefly so the user can redirect, then proceed. Do not ask.

**A hypothesis embedded in the question is a candidate, not a conclusion.** "Why is this frozen, I assume for backwards compatibility?" gets investigated independently, not confirmed. See the sycophancy trap in `references/epistemics.md`.

## Step 2. Establish the code anchor

Anchor the investigation in concrete code before searching history. You need the file paths and line ranges, the key symbols, the last few commits touching the target, and any PR numbers from merge subjects (pattern `(#1234)`).

```bash
git blame -L <start>,<end> <file>
git log --oneline -20 -- <file>
git log -1 --format=%B <commit>
```

Read PR bodies and review threads through the harness URIs, not raw API calls: `pr://<N>` for a pull request with its comments, `issue://<N>` for an issue. Both are cached and cheaper than a shell round trip.

Skip `graphify query` here. The knowledge graph indexes the code as it stands now, not the record of how it got that way, and `graphify-out/` is empty in any case. Git is the entry point for this skill.

## Step 3. Investigate the record

This repo has exactly one searchable historical record: **git history plus the GitHub PR and issue record**. There is no ticket tracker in use, no team chat integration, no error tracking, no observability or analytics warehouse. Do not fabricate lanes for systems we do not have, and do not spend a subagent producing a "no source available" report.

Run the archaeology yourself for a narrow target. Delegate to a single `scout` subagent for a broad sweep (a long-lived file, many commits, several PRs), handing it `references/code-archaeology.md`, the code anchor from Step 2, and the user's question verbatim.

A behavioral claim that history only implies can be confirmed by running the test that pins it: `bun run test:api <pattern>`, `bun run test:frontend <pattern>`, or `bun test <path>` for a single file. A passing frozen-vector test is direct evidence that the byte layout is deliberate, though still not evidence of why those bytes were chosen.

Whoever runs it collects evidence and does not answer the question. Epistemic discipline for the collection pass:

- **Do not confuse mechanics with motivation.** A commit changing `limit = 50` to `limit = 100` shows the change, not why. The explanation lives in the commit message, PR description, linked issue, or review comments.
- **Do not infer intent from code style.** "The author chose a functional approach" is an observation about code, not evidence of intent. Claim intent only when the author stated it.
- **Preserve uncertainty.** If one reading is more plausible but not certain, say exactly that. Do not collapse ambiguity to look decisive.
- **No silent substitutions.** If the question is about the receipt signature and you only found evidence about the checkpoint chain, do not present the latter as an answer to the former.
- **Track what you searched, not just what you found.** Record queries verbatim. An absence is only useful if the reader knows what was looked for.
- **Resist the story.** If three pieces of evidence line up and a fourth contradicts them, the contradiction is the most interesting finding.

## Step 4. Synthesize

Weigh the evidence and sort every claim into a confidence tier from `references/epistemics.md`: Direct, Supported, Inferred, Speculative, Unknown. The tier decides which output section a claim lands in and how it is phrased.

Then run the **calibration check** from `references/epistemics.md` before finalizing. Non-negotiable: every claim in "What We Found" carries a citation, phrasing matches its tier, no claim treats the code as evidence for its own intent, and there is a real "What We Don't Know" section. An output with no gaps is suspicious.

Do not rewrite the confidence language when presenting. Dropping the hedges to sound more authoritative is the exact failure this skill exists to prevent.

## Output Format

**The Question.** Restate what was asked, concisely.

**The Code in Question.** File paths, line ranges, key symbols. One or two lines so the reader is anchored.

**What We Found (direct evidence).** Claims with explicit citations (commit hash, PR number, issue number, `file:line` for a code comment). Each bullet is something we have textual evidence for. Quote or closely paraphrase the source.

**What We Can Reasonably Infer.** Claims supported by indirect evidence or converging signals but stated nowhere. Each bullet must expose its inference chain: "Given A and B, C is likely because D." Hedged language only.

**Competing Hypotheses.** If the evidence fits several stories, list them with the evidence for and against each. Do not force a winner the record does not support. Skip when the answer is clear.

**What We Don't Know.** Explicit gaps. Be specific: "searched the history of `receipt-verify.ts` with `git log -S 'dualSignature'` and read PRs #41 and #47; none states why the second signature is server-side" beats "we don't know".

**Sources Consulted.** The coverage map. State what was searched and what came back empty, so the reader can judge breadth. Short and honest here:

- Git history: `git log --follow -- apps/api/src/audit/receipt.ts`, `git log -S 'epochBoundary'`, blame of lines 40-72. Found PR #47 introduced the dual signature.
- PR and issue record (`pr://47`, `issue://31`): read PR #47 body and all review comments. The body states the problem; no reviewer discusses the alternative.
- Ticket tracker: none. This repo tracks work on GitHub only and not visibly in-repo, so no ticket rationale exists to search.
- Team chat, error tracking, observability, analytics: no such system is connected to this repo. The conversational and runtime record was not searchable. Gap, not a choice.

**Preserve / Change / Avoid / Risk.** When the question is a precursor to changing this code, convert the lineage into a constraint set that feeds the change:

- **Preserve.** Invariants the history shows were deliberate, with citations. In this codebase this is usually a wire format, a frozen test vector, a signature domain separator, or an epoch boundary rule.
- **Change.** What the history shows is incidental and safe to move.
- **Avoid.** Approaches the record shows were tried and rejected, and why.
- **Risk.** Where the rationale is Inferred, Speculative, or Unknown, so the change author knows which parts of the design they are touching blind.

## Common Failure Modes

- **Confident storytelling.** A plausible narrative built from thin evidence. A bullet with no citation belongs in "Inferred" or "Hypotheses".
- **Citing the code as evidence for its own intent.** Motivation comes from an external source or is labeled inference.
- **Recency bias.** The newest commit is not authoritative. Current shape is usually accretion. Trace back.
- **Sycophantic agreement.** Confirming the hypothesis the question embedded.
- **Skipping the gaps section.** The honest accounting is part of the value.

## Reference Files

- `references/epistemics.md`. Confidence tiers, phrasing guide, sycophancy trap, contradiction handling, calibration check. Mandatory.
- `references/code-archaeology.md`. The git and review-record playbook: pickaxe searches, rename tracking, defensive-code signals, pitfalls.
