---
name: unslop
description: Removes the vocabulary, punctuation, and formatting tells that mark prose as machine-written, and enforces the repo-wide em dash ban. Use when writing or reviewing prose that ships, meaning files under docs/, OpenAPI summary and description strings, a suggested commit name, or PR text.
---

# Unslop

Edit prose to remove the patterns that mark it as machine-written.

## Scope

This skill covers prose that ships or is read by a human outside this session:

- files under `docs/`
- OpenAPI `summary` and `description` strings in `apps/api/src/modules/**`
- the conventional-commit name suggested at the end of a task, and any PR text
- durable notes under `ai-output/other/` and the work log at `ai-output/work/[name]/progress.md`

It does not cover agent status reports. Those follow the AGENTS.md output-discipline block (Completed / Changed Files / Tests / Blockers, no essays), which deliberately wants terse labelled fragments. Do not apply the rules below to a status report, and do not let a status report's shape leak into prose that ships.

For document structure, mode selection, and sentence-level style, call the Skill tool with `technical-writing`. This skill owns only the slop catalogue.

## Process

1. Scan the text against the patterns below.
2. Rewrite. Preserve meaning, match the intended tone.
3. Self-audit: ask what still makes this obviously machine-written, then fix it.

## Patterns to detect and fix

### Language

1. **AI vocabulary.** Additionally, crucial, delve, enduring, enhance, fostering, garner, interplay, intricate, landscape (abstract), pivotal, showcase, tapestry (abstract), testament, underscore, vibrant. Replace with plain words.
2. **Fancy ways to say "is".** "serves as", "stands as", "boasts", "features". Say "is" or "has".
3. **"Not just X, but Y."** State the point directly instead.
4. **Rule of three.** Forcing ideas into groups of three. Use the natural number.
5. **Synonym cycling.** Protagonist, main character, central figure, hero all in one paragraph. Pick one, repeat it.
6. **False ranges.** "from X to Y" where X and Y are not on a meaningful scale. List the items directly.

### Style

7. **Em dashes.** Never use an em dash. This is repo law, not a preference. Use a period or a comma. Do not trade the tell for another one: no en dashes, no parentheses standing in for the dash, no hyphen used as a dash. If a thought needs separation, end the sentence.
8. **Colon overuse.** A colon is fine before a list or an example. It is not a mid-sentence connector. "If you are coming from traditional automation: instead of registering event handlers, you describe conditions" gains nothing from the colon. Rewrite so the point stands without the comparison framing.
9. **Boldface overuse.** Do not bold every proper noun or acronym.
10. **Inline-header lists.** The tell is a bold label and colon that restates the line: "**Performance:** Performance improved...". Convert those to prose. A bold lead-in that ends in a period, names the item, and is followed by genuinely new detail ("**Schema in TypeScript.** Tables live in one file.") is fine.
11. **Title case headings.** Use sentence case.
12. **Decorative emojis.** Remove them from headings and bullets.
13. **Curly quotes.** Replace with straight quotes.

### Filler

14. **Filler phrases.** "In order to" becomes "To". "Due to the fact that" becomes "Because". "It is important to note that" gets deleted.
15. **Excessive hedging.** "could potentially possibly be argued that it might" becomes "may".
16. **Generic conclusions.** "The future looks bright." State a specific plan or fact, or cut the paragraph.

### Jargon

17. **Abstract metaphor nouns.** Substrate, wedge, vector, locus, vantage, nexus, primitive (as noun), harness (as metaphor), surface (as in "API surface"), bedrock, scaffolding (as metaphor), modality, paradigm, gold-plating, ratchet (as metaphor), evacuate (for moving code), endgame, north star, flywheel. These read as technical but almost always have a plainer concrete word. "Substrate" becomes "base". "Wedge in" becomes "add". "Vector" becomes "way" or "method". "Gold-plating" becomes "more than the job needs". "Ratchet" becomes the mechanism's real name, or "a limit that only tightens". "Evacuate" becomes "move out". "Endgame" becomes "the last phase". Pick the concrete word. When you meet a new offender, add it here with its replacement.

### Plain speech

18. **Say what it does, not how it feels.** "the database stays close at hand", "SQL you can read", "types that follow your schema" all name a feeling. The fix names the mechanism or a number: "`.toSQL()` returns the exact string sent to the database", "a column rename fails the build". Ask what the sentence tells the reader to do or know, then write that. If you cannot restate it as a concrete instruction, fact, or number, cut it. One more check: if the sentence could appear unchanged in another project's docs, it says nothing about this one. Cut it.
19. **Shorten or split dense sentences.** If the reader has to backtrack to parse a sentence, break it in two or drop clauses. One idea per sentence.
20. **Active voice.** Catch "is/are/was/were + past participle" and name the actor. "queries are validated" becomes "the compiler validates queries". "the file is parsed by the loader" becomes "the loader parses the file". Passive is fine only when the actor is unknown or genuinely does not matter.
21. **Cut adverbs, or use a stronger verb.** "runs quickly" becomes "is fast", or the number. "significantly improves" becomes the measured delta. An adverb propping up a weak verb means the verb is wrong.
22. **Prefer the plain word.** "utilize" becomes "use", "leverage" becomes "use", "facilitate" becomes "help", "numerous" becomes "many", "in the event that" becomes "if". The fancier synonym is rarely clearer.
