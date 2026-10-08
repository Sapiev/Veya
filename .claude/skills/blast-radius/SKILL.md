---
name: blast-radius
description: "Find what a change could break somewhere else before it ships, beyond the diff, and prove the one fact it is safe because of by running real code instead of writing it up. Use for 'blast radius of X', 'what could this break', or reviewing a small diff you don't trust."
disable-model-invocation: true
---

# Blast radius

Find what a change breaks somewhere else, before it ships. Use for "blast radius of X", "what could this break", or reviewing a small diff you don't trust yet.

Listing the callers is not the job. `lsp references` gets those in one call. The job is the breakage a symbol search cannot reach.

## The structural pass is necessary and not sufficient

Start structural, then stop trusting it.

- **`lsp references`** on every symbol the diff adds, changes, or deletes. This is the call graph, and you should have it before you think about anything else. Necessary.
- **Not sufficient, and the reason is mechanical:** `lsp` resolves *symbols*. It does not resolve *bytes*. A signature preimage, a stored column, a frozen test vector, a JSON shape crossing a process boundary, a file a second runtime parses: none of these are symbol references, so a clean `lsp references` result on a byte-format change is not evidence of anything. Treat "`lsp` found nothing else" as the start of the search, never the end of it.
- **`fallow`** for changed-code risk: which modules the diff perturbs, which boundaries it crosses, which cycles it sits inside. AGENTS.md mandates a `fallow` pass before finishing anyway, so run it early and read it as a blast-radius input rather than a closing chore.
- **`ast_edit`** once you know the shape of the sweep. If the fix is "every call site gains an argument", that is an ast-grep codemod, not 40 hand edits that each risk a typo.

## Don't trust your own writeup

A blast-radius writeup that sounds right is worthless. It reads as convincing whether or not it is true, and that is the trap you are walking into. So don't hand back the writeup. Find the one or two facts the whole thing depends on and prove them by running code. Words are where you start, not what you ship.

### How sure are you

For each fact the change's safety depends on, get it as far down this list as is cheap, and say where it stopped.

1. You said so. Worthless on its own.
2. You pointed at the line. A real `file:line`, or the library's own source.
3. You showed the bad case can't happen. You walked the failure step by step and it doesn't reach.
4. You ran it. A script or test that calls the real code and fails loud if you're wrong.
5. You reproduced it in the running app.

Any safety fact you can't get to step 4, say so out loud. Don't write it up as settled. Step 4 is usually one small script that imports the same library the app ships and calls the exact function you're worried about.

## Steps

1. **Read the change.** The diff, the symbols it adds, changes, and deletes, and what it now does differently, including the part the diff doesn't spell out.
2. **Find the one fact it's safe because of.** Most changes that look scary are safe because of a single fact, like "this call only drops already-dead cache entries and does nothing else". Find that fact. If it holds, most of the scary cases die at once. Spend your time here, not on a long list of maybes.
3. **Look where grep stops.** The catalogue below. This is the step the whole skill exists for.
4. **Be honest about each risk.** Give it a real chance of happening and a real cost if it does. Keep the risks you confirmed; list the ones you checked and cleared separately. Cite a real `file:line`, a search that finds nothing is still an answer, and never make up a caller or an API.
5. **Prove the one fact.** Write a script or test that runs the real code, run it, and paste what happened. If you can't prove it cheaply, mark it unproven. Don't round up.

## Look where grep stops

Walk this list explicitly. Each entry is a reader that holds a contract with your change and that no symbol search will surface.

- **Wire formats.** The JSON an API returns, the shape the client destructures, a signature preimage, a canonical serialisation whose field order is load-bearing. Renaming a field is a symbol edit on one side and a silent protocol break on the other.
- **Stored bytes.** DB columns, their types, their constraints. 45 SQL migration files are 45 frozen statements about shapes you may be changing, and a migration already applied cannot be edited into agreement with a new type.
- **Pinned dependency source.** Read the source of the library you call, at the version in the lockfile, plus any local patch. Behaviour you assume from the docs is behaviour of some version.
- **Another process or language reading the same bytes.** A standalone script, a build step, a verifier, a PDF renderer, a generated artifact. It shares a format with your code and shares no module graph with it.
- **Frozen vectors and golden files.** A test that asserts exact bytes is a deliberate tripwire. If your change makes it fail, the question is which side is wrong, and the answer is not automatically the test.
- **Timing and lifecycle.** Microtasks, teardown, unmount, transaction boundaries, retries. When something runs is part of its contract.
- **Feature flags and config.** A branch that is off in your environment and on in another.
- **Three hops downstream.** A value that flows through two innocuous functions before it reaches the one that cares.

## Worked example: a receipt or audit-log wire-format change

Say the change touches how a revocation receipt or an audit entry is built: a field renamed, a field added, an encoding tightened, a canonical ordering adjusted. `lsp references` on the changed type gives you the API module and the service. It cannot give you any of these, and every one of them is a real reader:

- **`scripts/verify-receipt.mjs`**, the standalone verifier. It is a separate script outside both apps and it parses the receipt bytes itself. Nothing in the module graph connects it to your edit.
- **`apps/frontend/lib/receipt.vectors.test.ts`**, the frozen vectors. It spawns the standalone verifier and asserts that `lib/receipt.ts` rebuilds the same signed bytes. This is the one check that receipt-side and verifier-side have not drifted apart.
- **`turbo.json` documents exactly this hazard** in the comment above `globalDependencies`: a commit confined to `scripts/` otherwise selects the root package alone and skips that test, so `scripts/verify-receipt.mjs` is declared a global dependency to force the frontend back into `--affected`. When the repo's own build config carries a written warning about a cross-boundary reader, that is your map of where grep stops.
- **The 45 SQL migration files plus the Drizzle schema.** If the change alters what gets persisted, the column, its type, and its nullability are all separate statements that must agree, and the already-applied migrations are immutable.
- **`packages/Eden`**, the treaty client. It carries the API's response types across the process boundary into the frontend. A response-shape change lands in the frontend as a type error at best and a wrong render at worst.
- **The receipt PDF path.** Receipt-to-verifier parity means the human-readable artifact and the machine-verified bytes must describe the same event. A field the PDF prints and the verifier ignores is a divergence waiting to be discovered by an auditor.

The safety fact for a change like this is usually one sentence: "the signed preimage is unchanged, only the presentation layer moved". That is exactly the kind of claim that reads as true and can be false. Get it to step 4: run the vectors test and the standalone verifier and paste the output.

Proof commands for this class of change:

```
bun test apps/frontend/lib/receipt.vectors.test.ts
bun run test:api receipt
bun run test:frontend receipt
```

For a UI-visible break, `bun run test:pw:docker <pattern>` and read the machine-readable report at `apps/frontend/test-results/e2e-docker-report.json`.

## What to hand back

- **What it does.** What changed, including the part that isn't obvious.
- **The one fact it's safe because of.** State it, say which step of the ladder you got it to, and show the proof. If you couldn't prove it, write unproven.
- **Risks.** Only the real ones. Each names how it breaks, the `file:line`, how likely and how bad, and how to check. Paste the proof for the ones that matter.
- **Cleared.** What you checked and why it's fine, including the searches that came back empty.
- **Before this ships.** The cheapest test or repro that catches the real bug, including the script you wrote.

Leave the tree uncommitted. Report as Completed / Changed Files / Tests / Blockers, suggest a conventional-commit name, and log the outcome in `ai-output/work/[name]/progress.md`.
