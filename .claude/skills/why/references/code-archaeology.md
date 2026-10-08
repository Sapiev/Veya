# Code Archaeology (git and the review record)

## What this source contains

- Commit history (messages, dates, authors, diffs)
- PR descriptions, review comments, and discussion threads, read via `pr://<N>`
- Linked GitHub issues, read via `issue://<N>`
- Inline code comments, TODOs, FIXMEs, deprecation notes
- Tests. Names and assertions often encode the edge cases that motivated a change. In this repo, frozen test vectors are the strongest form of this: a byte-exact vector is a decision someone deliberately pinned
- Related files modified in the same commits (co-change signal)
- Any in-repo docs: `ai-output/other`, `ai-output/work/*/spec.md`, ADR-style notes, migration notes next to `.sql` files

This is the only historical record this repo actually has, and it is the most trustworthy one: it is tied directly to the diff that shipped.

## How to search it

Expand the seed commit list:

```bash
# Full history of the file through renames
git log --follow --oneline -- <file>

# Pickaxe: commits that added or removed this exact text.
# The single highest-value query. Use it on a constant, a domain separator,
# a magic byte length, a header string, a flag name.
git log -S '<exact_string_from_code>' -- <file>

# Same, but the needle is a regex rather than a literal
git log -G '<regex>' -- <file>

# Who wrote each line and when
git blame -L <start>,<end> <file>

# The full diff of a specific commit
git show <hash>

# Commits between two points affecting this file
git log <old>..<new> -p -- <file>
```

Drop `-- <file>` from a pickaxe search when the constant may have been introduced elsewhere and copied in. That is how you find the original decision instead of the copy.

For each substantive commit, pull the review context through the harness URIs rather than shelling out:

```bash
# Find the PR number from the merge commit subject, pattern (#1234)
git log -1 --format=%B <hash>
```

Then `read` `pr://<number>` for the body plus comments, and `read` `issue://<number>` for anything the PR closes or references. The review thread is usually where the real signal is: the body states the change, the comments debate the alternative.

Look for out-of-band context with the `grep` tool (not shell grep):

- Architecture or decision notes: pattern `architecture.decision|ADR|decision record` over `**/*.md`
- Markers near the target: pattern `(TODO|FIXME|HACK|XXX|NOTE)` in the target file, with context
- Tests naming the symbol: pattern `<symbol>` over `**/*.test.ts` and `**/*.spec.ts`
- Prior spec work: `ai-output/work/*/spec.md` and `progress.md` may hold the reasoning for recent audit, receipt, and auth work

## Defensive code deserves an incident sweep

If the target looks defensive (null guards, retry logic, timeout handling, rate limiting, feature flags, replay or nonce checks, clamp bounds, version pins), hunt specifically for a corrective origin. There is no incident tracker here, so the whole sweep happens in git:

- Commit messages containing "fix for", "hotfix", "defensive", "guard", "regression", "workaround"
- A `revert` commit followed later by a "re-apply with ..." commit. That pair is a strong signal that something broke in production and the fix is the difference between the two diffs
- Same-day branch-and-merge commits, which usually mean urgency
- Tests added in the same commit as the guard. The test name often states the failure the guard prevents
- A PR whose body describes a symptom rather than a feature

When you find such a pair, read the diff between the revert and the re-apply. That delta is the actual constraint.

## What good evidence looks like here

- A PR description that explains the problem being solved, not just the change
- A long review thread where alternatives were debated
- An inline comment near the target line that explains a non-obvious constraint
- A test named for the edge case that motivated the code
- A commit message that references an issue number
- A frozen vector or fixture whose bytes were deliberately pinned, with the pinning commit explaining why

## Common pitfalls

- **Squash-merge flatland.** If PRs are squashed, individual commits in the branch history are gone. Fall back to the PR body and comments via `pr://<N>`.
- **Misleading commit messages.** "Small refactor" sometimes hides an intentional behavior change. Look at the diff, not the message.
- **Cargo-culted patterns.** The author may have copied a pattern without understanding it. Check whether the pattern originated earlier in the codebase and investigate *that* commit. The pickaxe without a path filter is how you find it.
- **Bot commits.** Dependabot, Renovate, and automated backports carry no motivation. Skip them when hunting intent.
- **Treating code as evidence of intent.** The code is not evidence for why it exists. Evidence comes from commit messages, PRs, issues, comments, tests, docs. Never cite "the function is named X" as evidence of intent.
- **Reading only the newest commit.** The current shape is usually accretion across several decisions. Trace back until the pickaxe stops finding earlier occurrences.

## What to return

Every commit, PR, issue, comment, or test that bears on the question, with:

- The exact text, quoted
- The hash, PR number, issue number, or `file:line`
- Author and date
- Whether it is direct (explicitly addresses the question) or circumstantial
- The queries you ran, verbatim, including the ones that found nothing
