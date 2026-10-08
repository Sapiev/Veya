---
name: principle-build-the-lever
description: Build the script, codemod, or generator that does or proves the work instead of hand-applying it, so a reviewer can rerun one artifact. Use for any non-trivial sweep, migration, analysis, or verification.
disable-model-invocation: true
---

# Build the Lever

When the work is not trivial, build the thing that does it. Do not hand-apply.

**Why:** Two payoffs. Throughput, because a lever does the work the same way every time and reruns for free. Confidence, because the lever is one artifact a reviewer reads and reruns. Hand-done changes can only be re-verified by redoing them. A deterministic script turns "trust me" into "run this".

**The hard test:** applying this principle produces a file. If you cited the principle and there is no codemod, script, or generator in the diff, you did not apply it.

**Pattern:**

- Do the first unit by hand to learn the recipe. Then build the lever, rerun it on that unit, and diff against your hand-done version. If they differ, the recipe was wrong, not the diff.
- Make the lever safe to rerun. A reviewer will rerun it.
- Pick the smallest lever that does the job, never a framework.

**Our levers:**

- **`ast_edit` is the codemod lever.** ast-grep patterns over `apps/**` and `packages/**` for structural rewrites: renaming a call shape, threading a new argument, deleting a banned call. Matches stage as a proposal, so you inspect before applying. Reach for it before a hand sweep across N files. For pure symbol renames and reference updates, `lsp` is the smaller lever and wins.
- **A lever lives in `scripts/`** when it is durable and belongs to the repo, or in `ai-output/other/` when it is an analysis or a one-shot check that should outlive the session but is not repo machinery. Scratch goes to `ai-output/temp/`.
- **Verification levers count.** A rerunnable check (`bun test <path>`, a script that greps a report, a `fallow` invocation narrowed to the changed area) is a lever when it is what makes the work checkable.

**Two reconciliations with our rules, stated rather than hidden:**

1. **Upstream says "commit the lever". We never commit.** AGENTS.md is absolute: leave the tree uncommitted for review. So the lever ships uncommitted like everything else, listed under Changed Files, with a suggested conventional-commit name at the end. The intent survives: the lever is a repo artifact, not a throwaway, so write it to `scripts/` or `ai-output/other/` and reference it in `ai-output/work/[name]/progress.md`.
2. **Upstream says a deterministic lever beats fan-out. AGENTS.md says delegate AGGRESSIVELY.** Resolve it this way: **a deterministic lever beats fan-out for mechanical work; fan out for work that needs judgement per slice.** If one script can process every unit in one pass, run it yourself rather than spawning agents to hand-apply what a script does better. If each slice needs a real decision, fan out, and then write the lever as the shared brief every delegate reads so they inherit one hardened recipe instead of drifting.

**Balance:** the bar is triviality, not repetition. A couple of obvious edits need no lever. A one-off still earns one when the lever is what makes the work checkable.
