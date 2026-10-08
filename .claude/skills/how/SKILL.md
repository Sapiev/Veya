---
name: how
description: Explains how a subsystem works, at the level of a senior engineer onboarding onto it: runtime flow, key abstractions, where code lives, and the non-obvious sharp edges. Also answers placement and layering questions ("where should this live", "which package owns this"). Use when asked "how does X work", when walking a subsystem before changing it, or when a scout investigation needs a fixed output contract. Use the why skill for motivation and the code-review plugin for critique.
---

# How

Explore the codebase to answer "how does X work?" questions. Produce a clear architectural explanation: enough to build a working mental model, not annotated source code.

This skill exists mainly to give delegated exploration a **contract**. A `scout` subagent with no output format returns a wall of file paths. The prompts in `references/` fix that: an explorer knows when to stop, and an explainer knows what shape to hand back.

## Step 0. Try the knowledge graph, then fall back

AGENTS.md puts `graphify query` at the head of the investigation workflow, so run it first:

```
graphify query "<the question>"
```

`graphify-out/` is currently EMPTY, so today that query returns nothing. When it comes back empty, fall back immediately to `grep` for symbols, `glob` for structure, and `lsp` references for call chains. Say the graph is empty in every subagent prompt you write, so no explorer burns turns on a dead tool.

## Step 1. Understand the question and assess complexity

Parse what is being asked:

- "How does the receipt verifier work?", a subsystem
- "How do we handle epoch rollover?", a feature flow
- "How is `apps/api` structured?", an architectural overview
- "Walk me through what happens when a client submits a revocation", a runtime trace

Identify the scope. If ambiguous, state your best-guess interpretation before exploring. Do not ask. Let the user redirect if you are off.

**Assess complexity to decide the approach:**

- **Simple** (a single module, a small utility, a narrow question like "how does function X work"): skip explorers entirely. Go to Step 2b.
- **Complex** (a subsystem spanning multiple files or packages, a cross-cutting feature, a full architectural overview): fan out parallel explorers first, then synthesize. Go to Step 2a.

When in doubt, lean simple. You can always spawn explorers if the simple pass hits a wall.

## Step 2a. Explore (complex questions only)

Decompose the question into 2 to 4 parallel exploration angles, each a distinct slice so explorers do not duplicate work. Example split for "how does the audit log stay tamper-evident?":

- Explorer 1: data model, epoch boundaries, chain checkpoints
- Explorer 2: write path and server row signing
- Explorer 3: client verification and the frozen test vectors

The right decomposition depends on the question. Narrow questions: 2 explorers. Broad subsystems: up to 4.

Spawn them all in a single `task` batch, `agent: "scout"` (read-only research is exactly this job). Each explorer gets the base prompt from `references/explorer-prompt.md` plus one specific angle naming its slice. Each explorer must:

- Start broad: `glob` for relevant directories, `grep` for key types, interfaces, and exported names
- Follow the thread from an entry point: callers, callees, data flow, type definitions, `lsp` references
- Read the actual code, never guess from file names
- **Stop when it can describe the full path from input to output (or trigger to effect) without hand-waving any step**
- Note what is surprising, non-obvious, or what a newcomer would get wrong
- Report honest gaps. "I could not determine how X connects to Y" beats inventing a connection

Overlap between explorers is fine. The synthesizer reconciles. Then go to Step 3.

## Step 2b. Direct explain (simple questions)

Do it inline: `grep`, `read` the slice, `lsp` for references, then write the explanation yourself in the Output Format below. `references/explainer-prompt.md` holds the communication style. Delegate to a single `task` subagent only when your own context is already tight; a one-module question does not earn a fan-out.

Then go to Step 4.

## Step 3. Synthesize (complex questions only)

Once all explorers return, spawn **one** `task` subagent as the explainer, giving it every explorer's findings plus `references/explainer-prompt.md`. It writes the human-facing explanation.

Its duty is reconciliation, not concatenation: merge overlapping descriptions, and **resolve contradictions by re-reading the code itself**, not by picking the more confident explorer. Where the explorers left a gap, it says so.

When two explorers disagree about runtime behavior and the code does not settle it, the test suite is the oracle: `bun run test:api <pattern>`, `bun run test:frontend <pattern>`, or `bun test <path>`. Read the test first; run it only when reading is not enough.

## Step 4. Present

Present the explanation. You may lightly edit for clarity or add context from the conversation, but do not substantially rewrite it. The explanation is the product.

## Output Format

Follow this structure, adapted to the question. Not every section is needed for every question.

**Overview.** 1-2 paragraphs. What it is, what it does, why it exists. Enough to decide whether to keep reading.

**Key Concepts.** The important types, services, or abstractions. Brief definition of each. Not exhaustive, just the ones needed to understand the rest.

**How It Works.** The core of the explanation. Walk through the flow: what triggers it, what happens step by step, where data goes, the decision points. Prose, not pseudocode. Reference specific files and functions so the reader can go look, but do not dump code blocks unless a snippet is genuinely necessary.

**Where Things Live.** A brief map of the relevant files and directories. Not every file, just the ones needed to start working in this area.

**Gotchas.** Non-obvious or surprising things that would trip someone up. Historical context that explains why something looks weird. Known sharp edges.

## Reference Files

- `references/explorer-prompt.md`. Base prompt for each parallel `scout` explorer, including its stop condition and output structure.
- `references/explainer-prompt.md`. Prompt for the explainer, including communication style and the output format above.
