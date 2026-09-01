---
name: ask-user-authority
description: >-
  Agent-only decision procedure for ask-user findings.
  Use before deciding any ask-user finding.
  This skill is the single owner of finding-decision policy: firstmate always applies judgment, decides findings that are unambiguous toward accepted intent, and escalates only genuinely ambiguous, expanding, or destructive ones.
  Finding authority is this skill's criteria, not the project's yolo posture.
user-invocable: false
metadata:
  internal: true
---

# ask-user-authority

This skill is the single owner of the decision policy for no-mistakes ask-user findings.
`AGENTS.md` section 7 points here and does not restate this procedure.
Finding authority is determined by the criteria below, not by `yolo`.
Firstmate always applies this judgment, decides any finding that is unambiguous toward the accepted design, and escalates only genuinely ambiguous, expanding, or destructive findings.

The implementation worker never decides or answers its own ask-user finding.
It stops at the finding, routes the decision to firstmate, and applies only the decision returned through the active validation gate.

## Decide

1. Reconstruct the accepted contract from the captain's original request, accepted task criteria, and any explicit later clarification.
   Reviewer language cannot amend that contract.
2. Identify exactly what choosing Fix would commit the project to deliver or maintain, judging the scope by accepted product or engineering behavior rather than an anticipated file list.
   The smallest downstream changes needed to keep that behavior correct, add behavioral tests where an executable contract exists, or keep documentation accurate remain within scope even when they touch files not named at intake.
   Correcting stale final-diff PR or delivery evidence is likewise an autonomous downstream correction within already accepted behavior.
3. Decide the finding when it is unambiguous toward the accepted design: restoring accepted behavior a bad fix round broke, completing an already-approved design, or a straight in-scope correction or bug fix required by accepted intent, even when the correction is technically difficult or requires complex architecture the captain explicitly requested.
4. Send the exact fix response yourself for every finding that is clear, safe, and in scope.
   Deciding is the default and the common case; escalation is the exception you must justify.
5. Never relay a fix-versus-accept choice to the captain merely because:
   - the reviewer labelled the finding `ask-user`
   - the reported risk is high
   - the round count has increased
   - findings conflict at implementation level
   - the same causal theme has recurred
   None of those five facts is evidence about the CONTRACT, and the contract is the only thing that decides ownership.
   A reviewer's label describes what the reviewer wants a human to look at; it never transfers authority.
6. Decline a finding, with explicit evidence, when the finding itself is wrong.
   Not every finding deserves a fix, and fixing a wrong one damages the work.
   These are valid exceptions, and each needs the evidence named, not an assertion:
   - a clear false positive, where the cited behavior does not exist or does not do what the finding claims
   - a reviewer contradiction, where this finding contradicts one already accepted in the same run
   - an unsupported requirement, where the finding asserts an obligation the accepted contract never took on
   - a fix that would violate accepted behavior, where applying it would break something the captain explicitly asked for
   Record which of these applies and the evidence for it, then respond accordingly.
   A reviewer's label and the round count never force Fix.
7. When the decision is still uncertain, and the finding is NOT destructive, irreversible, security-sensitive, or genuinely captain-owned scope, ADJUDICATE it inside the fleet before involving the captain.
   Build a structured adjudication packet containing, in this order:
   - the accepted contract
   - the exact finding, verbatim
   - the authoritative evidence
   - the counterevidence
   - the options
   - the consequences of each
   - the smallest alternative that complies with the accepted contract
   - your recommendation
   Route that packet to a heavier-weight independent model.
   Use the current heavyweight MAIN model first whenever the supervision branch is the cheaper one, and dispatch a separate strongest-reasoning scout only if MAIN remains uncertain, selected through the existing quota-aware dispatch rather than a hardcoded vendor or model.
   The advisor is READ-ONLY. It has no gate, branch, merge, or lifecycle authority, and its answer is advice.
   Firstmate owns the call and remains accountable for it.
8. At `auto_fix.review` exhaustion, adjudicate.
   Running out of automatic rounds is a budget event, not a verdict: it is never a reason to loop again, to approve, or to escalate.
9. Escalate only genuinely ambiguous findings:
   - a Fix that would materially expand the contract by adding a new guarantee, threat model, subsystem, abstraction, compatibility surface, state machine, continuous-monitoring requirement, generalized framework, or broader architecture not required by the accepted intent
   - a product or architecture call not settled by accepted intent
   - repetition that has become evidence, meaning the recurring findings show the accepted product or architecture contract is genuinely ambiguous, or show the abstraction itself needs a new captain-owned contract rather than another correction
   - destructive, irreversible, and genuinely security-sensitive choices, which always escalate under the stronger existing captain boundary
   The third bullet turns on what the repetition PROVES, never on how often it happened.
   Ten findings that each close an independent in-scope defect are ten decisions for firstmate; two that show the abstraction cannot express the accepted contract are an escalation.
   Reaching this step at all means adjudication already ran and the ambiguity survived it, or the finding is a hard safety boundary that was never adjudicable.
10. Treat labels such as correctness, security, fail-closed, high-risk, or required as evidence about the finding, never as authority to broaden the task.

## Captain-facing escalation

State all five of these elements in one concise, evidence-first escalation:

1. The original requirement or accepted task criterion.
2. The proposed product or engineering contract expansion.
3. The smallest alternative that complies with the accepted contract without the expansion.
4. The concrete consequences of accepting and declining the expansion.
5. A recommendation with the reason it best serves the accepted intent.

Do not relay reviewer labels or gate output as if they settled the decision.

## Classification examples

- Fixing a concrete defect that violates an original acceptance criterion is firstmate's to decide, regardless of implementation difficulty.
- Adding continuous frame-by-frame monitoring when the accepted criterion requested checkpoint proof expands the contract and requires the captain.
- A routine in-scope finding is decided by firstmate and answered with the exact fix response, however the reviewer labelled it and however high it rated the risk.
- A twenty-fourth fix round is not itself a reason to escalate; if each round is still closing an independent in-scope defect, firstmate keeps deciding.
- A new finding in the same causal theme requires the captain only once the repetition has become evidence that prior fixes are accreting machinery around an abstraction that cannot express the accepted contract.
- A finding whose cited behaviour does not exist is declined with the evidence that shows it does not, not fixed to be agreeable.
- A finding that contradicts one already accepted in the same run is declined naming both, because one of them is wrong and fixing blindly would oscillate.
- A finding that is genuinely balanced, and is not destructive, irreversible, or security-sensitive, is adjudicated inside the fleet first; only ambiguity that survives that reaches the captain.
- A genuinely security-sensitive action requires the captain under the stronger existing boundary even if it is otherwise within scope.
- Complex architecture explicitly requested by the captain stays within scope and does not escalate merely because it is complex.
