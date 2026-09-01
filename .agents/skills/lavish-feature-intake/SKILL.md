---
name: lavish-feature-intake
description: >-
  Agent-only policy for mandatory Lavish interactive intake before significant Firstmate work.
  Owns significance classification, required intake content, captured-feedback acceptance,
  exemptions, task-boundary enforcement, and the Firstmate dashboard integration example.
user-invocable: false
metadata:
  internal: true
---

# Mandatory Lavish feature intake

Load this skill before planning, designing, implementing, or dispatching any work that might create a significant capability, workflow, product, prototype, UI/UX surface, service or API, data model, architectural component, cross-subsystem behavior, or Firstmate feature.
Uncertainty is significant until an intake proves otherwise.

## Classification

Significant work includes every new user-facing capability or workflow, UI/UX surface, product or prototype, service or API, data model, architectural component, cross-subsystem behavior, and Firstmate feature.
The only exemptions are bounded bug fixes, dependency or configuration updates, documentation, behavior-preserving refactors, and exact follow-ups already covered by an accepted intake.
An exact follow-up keeps its accepted intake only while goal, users, use cases, scope, constraints, and acceptance criteria remain materially unchanged.
A bug report that expands behavior, changes product intent, or leaves classification uncertain is significant.

Record an exemption with `bin/fm-lavish-intake.sh exempt <task-id> --reason <concrete reason>`.
The reason must identify the bounded exemption, such as `documentation-only` or `dependency pin update with no behavior change`.
Never infer not-applicable from a missing artifact, a small diff, a file path, or a familiar task name.

## Required intake

The artifact must state the product goal, intended users, use cases, scope, non-goals, constraints, visual or product references, key choices and options, acceptance criteria, and open questions.
The artifact must make choices visible, distinguish selected from queued state, and provide one explicit submit control that queues one keyed answer.
Existing accepted answers may prefill fields, but the captain must review and submit the current intake again.

Before authoring the first HTML revision, read current `lavish-axi --help`, `lavish-axi design`, and every matching playbook, including `input`, `plan`, and `comparison` for this gate.
Inspect the subject project first and match its current visual system when the artifact represents its UI or product.
Use `bin/fm-lavish-intake.sh template` as the portable starting point when no existing intake surface applies.
Do not use plain chat, a static HTML page, an opened-but-unsubmitted session, or an agent-written summary as intake evidence.

## Captured review loop

Run `bin/fm-lavish-intake.sh start` after the task exists in the authoritative backlog.
This opens the real artifact through `lavish-axi`, places the task under `captain-hold-lifecycle`, binds the source to that task, and arms the existing `fm-procevent-lavish.sh` adapter in the required order.
The implementation task remains held until the captured keyed answer releases it.
Do not run `lavish-axi poll` in a conversational turn or invent a second poller.

When the existing process-event source captures feedback, read its exact result and run `bin/fm-lavish-intake.sh record`.
That command accepts only a real Lavish feedback result captured in `state/procevent-inbox`, reuses `fm-captain-hold.sh` for the keyed release, writes hash-bound durable evidence, and acknowledges the captured result.
A result is not authority for merge, destructive, irreversible, security-sensitive, or other captain-owned action.
Route any unresolved captain choice through `captain-hold-lifecycle` before treating intake or review as complete.
The Lavish poll has a source-side loss window after feedback is cleared, so never claim lossless or at-least-once intake delivery.

The current interactive dashboard-style integration is `bin/fm-bearings-board.sh build`.
Use it as a live ordering example because it builds the stable surface, opens Lavish, binds `captain-hold`, and arms `fm-procevent-lavish` without creating another answer or polling system.
Do not modify dashboard product code to satisfy this gate.

## Enforcement and compatibility

`bin/fm-brief.sh` carries an explicit Lavish intake contract in new worker instructions.
`bin/fm-spawn.sh` verifies submitted evidence or an explicit exemption before creating a new worker endpoint.
`bin/fm-promote.sh` applies the same check when scout work becomes ship work.
The deterministic evidence owner is `bin/fm-lavish-intake.sh`; this policy owns meaning and procedure, while `captain-hold-lifecycle` owns captain answers and `process-event-sources` owns capture and wake durability.

A new significant task must not dispatch without a verified submitted receipt.
A new exempt task must carry a verified not-applicable receipt with its concrete reason.
An old brief or old task record without an intake contract remains launchable for in-flight compatibility, but no new generated brief may silently inherit that legacy path.
Relaunch, merge authority, destructive-action authority, security boundaries, supervision, and no-mistakes ownership remain unchanged.

Before declaring the work ready, run `bin/fm-doc-audience-check.sh`, `bin/fm-lint.sh`, and the relevant behavior tests.
