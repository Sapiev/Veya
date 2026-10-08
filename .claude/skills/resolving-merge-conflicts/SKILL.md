---
name: resolving-merge-conflicts
description: "Resolve an in-progress merge or rebase conflict by recovering the intent behind each side and preserving both, rather than picking a winner. Use when a merge or rebase has stopped with conflicts to resolve."
---

# Resolving merge conflicts

A conflict is not a formatting problem. Two people made two changes for two reasons, and the tool cannot see either reason. Picking a side is how a long-lived branch silently loses an invariant: on a branch like `feat/epoch-scoped-tamper-evident-audit-log` both sides may have touched the same crypto path, and the side you discard was also correct about something. Recover both intents first, then write the resolution that satisfies both.

## 1. See the current state

Find every unresolved conflict in one call:

```
read <file>:conflicts
```

The `:conflicts` selector returns one line per unresolved conflict block, so discovery is a read rather than a `git status` crawl followed by opening each file to hunt for markers. Use `grep` for `^<<<<<<<` across the tree only if you need to enumerate the conflicted files first.

Then establish what is being merged into what: which branch, which base, and which commits on each side touched these files.

## 2. Find the primary sources

For each conflict, understand deeply why each change was made and what the original intent was. In order of value:

- The commit messages on both sides.
- `pr://<N>` for the pull request that carried the change, including its review comments. A reviewer often stated the invariant in a comment that never made it into the code.
- `issue://<N>` for the issue that motivated it.
- The tests around the conflicted code. A test is the most literal statement of intent in the repo.

A resolution written without reading the sources is a guess with a plausible shape. That is the failure mode this step exists to prevent.

## 3. Resolve each hunk

Preserve both intents where possible. That is usually achievable and usually not what the markers suggest: the markers frame it as a choice, and it is normally a composition.

Where the intents are genuinely incompatible, pick the one matching the merge's stated goal, and say so explicitly in your report along with the tradeoff you accepted. Never bury an incompatibility silently.

Do not invent new behaviour. A resolution that introduces a third design neither side wrote is a change smuggled in through a merge, and it will not be reviewed as a change. Always resolve; never `--abort`.

## 4. Run the checks, in this order

```
bunx biome check --write            # lint and format
tsc --noEmit                        # per app: apps/api, apps/frontend
bun run test:api <pattern>
bun run test:frontend <pattern>
bun run test:pw:docker <pattern>    # anything touching apps/frontend
```

Fix whatever the merge broke. A conflict resolution that typechecks is not evidence the semantics survived, which is why the tests are not optional here.

**Never resolve a conflict by deleting the losing side's test.** A test that fails after your resolution is telling you the resolution dropped an intent, and deleting it converts a visible merge defect into an invisible one. AGENTS.md already bans suppressing a failure to make checks pass; this is the sneakiest form of it, because the deletion looks like ordinary conflict cleanup in the diff. If a test genuinely no longer applies because the merge deliberately removed the behaviour it covered, say that in your report as its own line item with the reason, so it gets reviewed as a decision rather than absorbed as noise.

## 5. Leave the resolution uncommitted

Leave the working tree resolved and uncommitted. Do not stage, do not commit. Suggest a conventional-commit name instead, for example `fix(audit): resolve epoch-chain conflict between checkpoint and revocation paths`.

If you are mid-rebase, continuing the rebase is unavoidable, because the remaining commits cannot be replayed any other way. Surface it to the user before you do it: say which commits remain, that continuing will create commits from them, and that the final state will still be left for review. Never continue a rebase silently.

Report as Completed / Changed Files / Tests / Blockers, listing for each conflict which intents you preserved and any tradeoff you accepted, and log the outcome in `ai-output/work/[name]/progress.md`.
