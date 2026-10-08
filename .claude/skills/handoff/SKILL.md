---
name: handoff
description: "Compact the current conversation into a handoff document a fresh session can pick the work up from, written into ai-output. Use when the user asks for a handoff, wants to end a session cleanly, or says the context is getting full."
disable-model-invocation: true
---

# Handoff

Session-to-session compaction: turn everything this conversation learned into one document a cold-start session can resume from. This is not the AGENTS.md "Handoff Contract (Required)" block, which is the fixed PROJECT RULES preamble every delegated subagent task must open with. That contract governs main-to-subagent dispatch inside a session; this skill governs one session handing off to the next. They share a name and nothing else.

## Where it goes

- Continuing named work: `ai-output/work/[name]/progress.md`. Update the existing file rather than adding a second one; AGENTS.md wants progress kept current, and a handoff is exactly a progress update with a reader in mind.
- No named work, throwaway: `ai-output/temp/handoff-<topic>.md`.

Never the OS temp directory and never an untracked path outside `ai-output/`. The whole point is that the next session can find it, and the next session knows the `ai-output/` convention.

## The document

It opens with the fixed PROJECT RULES block, verbatim, so the next session inherits the rules without needing to be told them:

```
PROJECT RULES (follow these exactly):

* SEARCH FIRST: use rg before reading files.
* GRAPHIFY: use graphify when available.
* FILE OUTPUT: use ai-output folders correctly.
* TESTS: run from repo root.
* API ROUTES: maintain OpenAPI documentation.
* AFTER EDITING CODE: run graphify update .
* RETURN: summary + changed files only.
```

Note under the block that `graphify-out/` is currently empty, so `graphify query` returns nothing and search means `grep` until it is rebuilt.

Then, in this order:

1. **Goal.** What the work is trying to achieve, in one paragraph. Not a task list: the thing that decides whether a task list is right.
2. **State.** What is done, what is in progress, what is untouched. Name the files. The tree is uncommitted, so say which files are dirty and why.
3. **Decisions and their reasons.** The load-bearing part. Every choice made in this session that a fresh session would otherwise relitigate, each with the reason it was made and, where it matters, the alternative that was rejected. A decision without its reason gets reversed by the next agent that finds it inconvenient.
4. **Open threads.** Unresolved questions, things you tried that did not work, and anything you deliberately deferred. Say what you already ruled out so the next session does not spend its first hour re-ruling it out.
5. **Verification state.** Which of `bunx biome check --write`, `tsc --noEmit`, `bun run test:api`, `bun run test:frontend`, `bun run test:pw:docker <pattern>` and `fallow` have been run, and what they said. Anything unrun is a hole the next session must close before finishing.
6. **Suggested skills.** Which skills the next session should call the Skill tool for, and why each one applies. Name them exactly, for example: call the Skill tool with `diagnosing-bugs` before touching the failing receipt-parity test.

## What to leave out

Do not replay the conversation. The harness keeps agent transcripts and the next session can read one directly with `history://<id>`, so a narrative retelling of what was discussed is duplicated bytes with a worse index. Capture the residue a transcript does not hold: the conclusions, and the reasons behind them.

Same rule for anything already written down. Do not restate specs, plans, ADRs, `issue://<N>`, `pr://<N>` bodies, or diffs. Reference them by path or URI and move on.

Redact secrets: API keys, tokens, passwords, personally identifiable information. This file lives in the repo tree.

If the user said what the next session is for, tailor everything to that. Details that do not serve that focus get cut, not kept for completeness.

## Finishing

Leave the tree uncommitted. Report as Completed / Changed Files / Tests / Blockers, and suggest a conventional-commit name such as `docs(work): record handoff for audit-receipts`.
