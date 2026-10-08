---
name: principle-separate-before-serializing-shared-state
description: Eliminate the shared write target before reaching for a lock, and serialize structurally only when one writer is a real invariant. Use when concurrent actors (requests, test files, parallel subagents) might write the same row, registry, or file.
disable-model-invocation: true
---

# Separate Before Serializing Shared State

Two actors want the same mutable thing. First ask whether they need the same mutable thing. Usually they do not, and the sharing is an accident of where someone put the write. Delete the sharing. Only when one canonical writer is a real invariant do you serialize, and then you serialize structurally, never by convention.

**Why:** Races are intermittent, machine-dependent, and expensive. They pass on your box and go red on CI, or the reverse. Telling parallel actors to take turns is not concurrency control. "We need a lock" is a smell to check, not the answer.

**Pattern:**

1. Name the shared mutable target: a row, a process-wide registry, a file, a queue.
2. **Default: remove the sharing.** Give each actor its own owned target and merge at the read boundary.
3. **Only when one writer is a genuine invariant, serialize at the narrowest structural point** that still holds the invariant. Never a broad lock standing in for a narrow one.

**Our four cases:**

- **Bun module mocks (`7fb9ea7`).** `mock.module` writes the process-wide module registry and Bun never undoes it, so one test file's partial stub poisoned every file loaded after it, in filesystem order, differently per machine. Fix was separation, not a lock: `apps/frontend/lib/testing/mockModule.ts` scopes each stub to the installing suite and restores the real namespace in `afterAll`. Per-suite ownership, no shared registry state surviving the file.
- **Audit and trash write races (`0eaab8f`).** Here one writer *is* the invariant: a vault's audit chain is a single ordered hash chain, so two appends cannot both read the same tip and claim the same `seq`. Serialized structurally at the narrowest point, `select ... for update` on the one vault row inside `readChainHead`, so appends to *that* vault queue and nothing else does. Read-only `getTip` deliberately skips the lock: taking a write lock to answer a question turns every reader into a rival.
- **Epoch-chain appends.** Rotation appends under two epochs in one bracket. Want a single writer per chain, not a lock wrapped around the whole rotation service. Scope the serialization to the chain, not to the operation that touches it.
- **Parallel subagents.** Fan-out under `ai-output/work/[name]/` must not share one `progress.md`. Give each agent its own file and merge at report time. Two agents appending "their own section" to one file is still shared mutation.

**Test:** if your answer is a lock, say what invariant requires one writer. No invariant means you have not separated yet.
