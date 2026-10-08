---
name: logic-prototype
description: "Build one self-contained HTML file that drives a pure reducer or state machine through its hard cases, so the behaviour can be felt before it is committed to. Use when a state model, transition set, or data shape looks fine on paper but its edge cases are hard to reason about: epoch chains, revocation receipts, checkpoint lifecycles, and anything where the question is \"does this state model actually handle X then Y\"."
---

# Logic prototype

A prototype is throwaway code that answers a question. This one answers questions about **business logic, state transitions, or data shape**: the kind of model that reads reasonably in a design doc and only feels wrong once you push it through real cases.

The artifact is a single, self-contained HTML file that anyone can drive by clicking buttons. Because there is nothing to install, you can hand it to a non-developer and let them feel the model. So it speaks their language, not the code's.

This repo keeps building exactly the shapes this technique is for. The epoch chain, the dual-signed revocation receipt lifecycle, the chain-checkpoint progression: each is a state machine with illegal transitions that matter, and each is cheaper to get wrong in an HTML file than in signed, persisted, verifier-parity-checked crypto code.

**This is not the UI branch.** If the question is "what should this look like", call the Skill tool with `prototype` instead: it owns UI divergence, enforces a named divergence axis per variant, and specifies its picker verbatim.

## When this is the right shape

- "I am not sure this state machine handles the edge case where X then Y."
- "Does this data model actually let me represent the case where..."
- "I want to feel out what the API should look like before writing it."
- Anything where someone wants to press buttons and watch state change.

## Rules

1. **Throwaway from day one, and clearly marked as such.** The HTML shell lands in `ai-output/temp/`, named so a casual reader sees immediately that it is a prototype and not production. It never goes near `apps/`.
2. **Trivial to run.** A single HTML file the user double-clicks. If a run command is genuinely needed, it is one command in the project's task runner, `bun run <name>`, with no arguments to remember.
3. **No persistence by default.** State lives in memory. Persistence is the thing the prototype is *checking*, not something it should depend on. If the question explicitly involves storage, hit a scratch file with an obvious "PROTOTYPE, wipe me" name.
4. **Skip the polish.** No tests, no error handling beyond what makes it runnable, no abstractions. The point is to learn something fast.
5. **Surface the state.** After every action, render the full relevant state so the user can see what changed.
6. **Capture the answer, then stop.** The HTML shell stays in `ai-output/temp/`. The verdict, meaning the question and the answer it settled, goes in `ai-output/work/[name]/progress.md`. Only the validated decision moves into the real code.

## Process

### 1. State the question

Before writing code, write down what state model you are prototyping and what question you are answering. One paragraph, visible at the top of the demo, not buried in a comment. A logic prototype that answers the wrong question is pure waste, so make the question explicit enough to be checked later, whether the user is watching now or coming back to it later.

### 2. Isolate the logic in a portable module

Put the actual logic, the part answering the question, in a single `<script>` block written as a small pure module that could be lifted out and dropped into the real codebase. The page around it is throwaway; this module is not.

The right shape depends on the question:

- **A pure reducer**, `(state, action) => state`. Good when actions are discrete events and state is a single value.
- **A state machine** with explicit states and transitions. Good when "which actions are even legal right now" is part of the question. This is usually the right one for a chain, receipt, or checkpoint lifecycle, because the illegal transitions are the interesting part.
- **A small set of pure functions** over a plain data type. Good when there is no implicit current state, just transformations.
- **A class or module with a clear method surface** when the logic genuinely owns ongoing internal state.

Pick whichever shape fits the question, *not* whichever is easiest to wire to a page. Keep it pure: no DOM, no `document`, no button handlers reaching inside it. The page calls into it; nothing flows the other direction. That is what makes the prototype useful past its own lifetime, because once the question is answered the validated reducer lifts into the real module on its own.

### 3. Build the shareable HTML file

One file, plain HTML/CSS/JS. No framework, no bundler, no server, everything inline so it opens by double-click and survives being emailed around.

Write it for a non-developer. Every label is in domain language, not code: buttons and state read like the business, not the reducer. Explain in plain words what is happening.

Lay it out top to bottom:

1. **Title and one-line explanation** of what this demo lets you explore, which is the question from step 1.
2. **Current state**: the full relevant state as a readable panel with labelled fields, not a raw JSON dump, re-rendered after every click so the change is visible. Where it helps, call out what just changed.
3. **Free-play buttons**: one per action, always available, so anyone can poke at the model in any order. Each click dispatches its action and re-renders.
4. **Guided walkthroughs**: a set of scenarios, one per tab. Each tab holds a short plain-language description of the situation it sets up and what to watch for, and underneath it the ordered buttons to press. Each step is a real button: clicking it performs the action and advances. Starting a walkthrough resets to a known initial state so the scenario runs the same way every time.

Choose scenarios that demonstrate the awkward cases: the happy path, a tricky edge case, and an attempt at something that should be illegal.

Keep it beautiful but restrained: clean typography, generous spacing, one accent colour. No animations, nothing that competes with the state and the buttons.

### 4. Hand it over

Open it for the user or give them the path. The interesting moments are when they say "wait, that should not be possible" or "huh, I assumed X would be different". Those are bugs in the *idea*, which is the entire point. If they want new actions or another scenario, add them. Prototypes evolve.

Verify it yourself first: `browser` can open the file, click through every walkthrough, and confirm the state panel updates and the console is clean. Handing over a demo that throws on the second button teaches nothing.

### 5. Capture the answer

Fold the validated decision into the real code. The reducer or machine lifts into the real module; the HTML shell stays in `ai-output/temp/` as a re-runnable record of how the question was settled. Write the question and the verdict into `ai-output/work/[name]/progress.md` so the decision survives without the file.

## Anti-patterns

- **Do not add tests.** A prototype that needs tests is no longer a prototype. This licence stops at the prototype and must never leak into the code it informs: the moment the validated reducer lands in `apps/`, it is crypto or audit-log code under AGENTS.md, which means coverage for the changed behaviour, `bun run test:api` or `bun run test:frontend` green, and no suppressed failures. The prototype skips tests because it is going to be deleted. The real thing is not going to be deleted.
- **Do not wire it to the real database.** In-memory state unless the question is specifically about persistence.
- **Do not generalise.** No "what if we wanted to support X later". The prototype answers one question.
- **Do not blur the logic and the page together.** If the pure module touches the DOM, `document`, or button handlers, it is no longer liftable. Keep the page a thin shell over a pure module.
- **Do not reach for a framework, bundler, or server.** One file the recipient double-clicks. A React app or a dev server defeats "shareable".
- **Do not ship the HTML shell into production.** The page is optimised for being clicked through by hand. The logic module behind it is the part worth keeping.

## Finishing

Leave the tree uncommitted. Report as Completed / Changed Files / Tests / Blockers, suggest a conventional-commit name for whatever the prototype's verdict changed in real code, and log the question and answer in `ai-output/work/[name]/progress.md`.
