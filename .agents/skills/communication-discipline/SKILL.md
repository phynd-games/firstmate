---
name: communication-discipline
description: >-
  Concise communication policy for the captain session and workers. Load before
  composing a user-facing response, worker instructions, progress update, or review result.
user-invocable: false
metadata:
  internal: true
---

# Communication discipline

Optimize for signal, not ceremony.
Keep internal reasoning and tool work as thorough as needed, but keep visible prose to the minimum that preserves correctness, decisions, evidence, and next actions.

Answer the question or state the result first.
Do not add greetings, praise, preambles, repeated context, or a conclusion that merely restates the answer.
Do not recap work the reader just watched.
Do not provide status inventories, implementation tours, file-by-file summaries, or unsolicited menus unless requested or required for a decision.
Use bullets or a short paragraph when that is clearer than prose.

Ask only questions that block correct progress.
Combine related questions into one message and include the recommended default when a choice is needed.
Do not ask a question whose answer can be established from the repository, an executable check, or an authoritative tool.
Prefer one bounded request for missing information over repeated back-and-forth.

Worker instructions should contain the objective, acceptance criteria, constraints, relevant context, and return format once.
Workers should work independently, avoid narrating routine steps, and send sparse status notifications for milestones, blockers, decision requests, or final results.
A short status notification is not a substitute for a substantive answer.
Captain-facing brevity does not impose a sentence limit on worker-to-firstmate findings, concrete answers, failed-check explanations, decision requests, or handoffs.

## Substantive worker answers

Give firstmate enough detail to assess the conclusion without reconstructing missing reasoning or guessing what happened.
Use a concise conclusion followed by the material observations, artifact and source references, reasoning, counterevidence or uncertainty, verification results and limitations, unresolved questions, and recommended next action.
Include exact commands, exit results, source or commit identities, and artifact locations when they determine whether the claim is true.
Distinguish file changes from commits, publication from landing, a tool's return from the underlying command's completion, process presence from readiness, and observed failure from an inferred cause.
State failed, skipped, timed-out, and unperformed checks explicitly; do not bury them under a success summary.
Scale detail to the question rather than requiring transcript dumps or repeated narration.
Put substantial evidence in a durable report and use a compact status pointer to notify firstmate.
Firstmate reads the relevant complete answer or report before deciding, steering, or composing the shorter captain-facing summary; the pointer or status line alone is not the answer.
For transferring retained work to a fresh worker, follow the reconciliation and handoff procedure in `../stuck-crewmate-recovery/SKILL.md` rather than treating an old conversation or runtime record as a verified handoff.

When the pointer is a Markdown document under this home's `data/`, run `bin/fm-docs-reader.sh url <path>[#anchor]` and give the captain the URL it prints, which is the local document reader's verified address for that exact page.
When the command fails, give the file path instead and say in one clause that the reader is unavailable; never compose a `localhost` or `127.0.0.1` address yourself, and never send a reader URL to Relay or any other remote reader, because the address exists only on the captain's machine.

Self-review visible output before sending:

- Is the result or requested decision in the first sentence?
- Can any sentence be removed without losing correctness or actionability?
- Did I repeat something already visible or established?
- Did I distinguish observed evidence from inference?
- Did I include only the next action or decision that matters?

Short output must never omit a failure, uncertainty, safety constraint, validation result, or captain decision.
Conciseness controls presentation and coordination overhead; it never lowers verification depth or engineering quality.
