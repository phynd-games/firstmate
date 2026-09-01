---
name: ask-user-authority
description: >-
  Agent-only decision procedure for ask-user findings.
  Use before deciding any ask-user finding and before approving a validation review step.
  This skill is the single owner of finding-decision policy: firstmate classifies every finding by material consequence, fixes the material ones, dismisses the immaterial ones with recorded evidence, and escalates only genuinely ambiguous, expanding, or destructive ones.
  Finding authority is this skill's criteria, not the project's yolo posture.
user-invocable: false
metadata:
  internal: true
---

# ask-user-authority

This skill is the single owner of the decision policy for no-mistakes ask-user findings and for approving a validation review step.
`AGENTS.md` section 7 points here and does not restate this procedure.
Finding authority is determined by the criteria below, not by `yolo`.
Firstmate always applies this judgment, decides any finding that is unambiguous toward the accepted design, and escalates only genuinely ambiguous, expanding, or destructive findings.

Every finding gets one of four dispositions, and every disposition is recorded per finding with the reason for it: fix, dismiss, adjudicate, or escalate.
Never report or reason about findings as an undifferentiated batch.
A summary that disposes of a whole round in one blanket phrase - "accept none", "accept all", "no changes needed" - is not a disposition; it is the absence of one, and it hides exactly the material defect this procedure exists to catch.

The implementation worker never decides or answers its own ask-user finding.
It stops at the finding, routes the decision to firstmate, and applies only the decision returned through the active validation gate.

## Decide

1. Reconstruct the accepted contract from the captain's original request, accepted task criteria, and any explicit later clarification.
   Reviewer language cannot amend that contract.
2. Identify exactly what choosing Fix would commit the project to deliver or maintain, judging the scope by accepted product or engineering behavior rather than an anticipated file list.
   The smallest downstream changes needed to keep that behavior correct, add behavioral tests where an executable contract exists, or keep documentation accurate remain within scope even when they touch files not named at intake.
   Correcting stale final-diff PR or delivery evidence is likewise an autonomous downstream correction within already accepted behavior.
3. Classify the finding by MATERIAL CONSEQUENCE before choosing a disposition, and record which class you assigned.
   A finding is material when, substantiated, it means the shipped work is wrong, unsafe, or falsely evidenced.
   These classes are material:
   - correctness, where the code produces a wrong result, a wrong state, or a crash
   - security, where the change widens what an attacker or an untrusted input can reach
   - lifecycle, where startup, recovery, ownership, teardown, or continuity can be left in a broken or duplicated state
   - provenance, where a record, attestation, or piece of delivery evidence would claim something that is not true of the thing shipped
   - behavioral contract, where the change breaks an accepted, executable, or documented promise other code or an operator relies on
   - test integrity, where a test would pass without exercising the behavior it names, or an existing gate is weakened, masked, or made vacuous
   A material finding is FIXED once substantiated.
   Materiality is a property of the consequence, never of the reviewer's severity label, the effort the fix costs, or how late in the run it arrived.
   Judge the consequence yourself against the code and the accepted contract; a finding the reviewer called minor is still material if its consequence is, and a finding the reviewer called critical is still immaterial if its consequence is not.
4. Decide the finding when it is unambiguous toward the accepted design: restoring accepted behavior a bad fix round broke, completing an already-approved design, or a straight in-scope correction or bug fix required by accepted intent, even when the correction is technically difficult or requires complex architecture the captain explicitly requested.
5. Send the exact fix response yourself for every finding that is clear, safe, and in scope.
   Deciding is the default and the common case; escalation is the exception you must justify.
6. Never relay a fix-versus-accept choice to the captain merely because:
   - the reviewer labelled the finding `ask-user`
   - the reported risk is high
   - the round count has increased
   - findings conflict at implementation level
   - the same causal theme has recurred
   None of those five facts is evidence about the CONTRACT, and the contract is the only thing that decides ownership.
   A reviewer's label describes what the reviewer wants a human to look at; it never transfers authority.
7. Dismiss an immaterial finding, with explicit evidence, rather than fixing it to be agreeable.
   Not every finding deserves a fix, and fixing a wrong one damages the work.
   These are the valid grounds for dismissal, and each needs the evidence named, not an assertion:
   - a clear false positive, where the cited behavior does not exist or does not do what the finding claims
   - a duplicate, where the same defect is already dispositioned elsewhere in this run, naming that finding
   - a reviewer contradiction, where this finding contradicts one already accepted in the same run
   - an unsupported requirement, where the finding asserts an obligation the accepted contract never took on
   - a fix that would worsen accepted behavior, where applying it would break something the captain explicitly asked for
   - an immaterial nit or style preference, where the consequence falls in none of the material classes and the evidence for that is stated, not assumed
   Every dismissal is recorded PER FINDING and durably, never as a batch and never only in conversation: write the finding's identity, the ground above, and the concrete evidence into the gate response itself, so the run's own record carries why it was not fixed.
   A dismissal you cannot state that way is not a dismissal; treat it as unresolved and go to the next step.
   A reviewer's label and the round count never force Fix, and neither of them ever licenses a dismissal.
8. When the decision is still uncertain, and the finding is NOT destructive, irreversible, security-sensitive, or genuinely captain-owned scope, ADJUDICATE it inside the fleet before involving the captain.
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
9. Adjudicate before disposition, not after it, whenever either of these is true:
   - the finding's MATERIALITY itself is uncertain, meaning you cannot say from the code and the accepted contract whether its consequence falls in a material class
   - the run has reached the configured `auto_fix.review` round budget, which this repository sets to five
   Running out of automatic rounds is a budget event, not a verdict: it is never a reason to loop again, to approve, or to escalate.
   Uncertain materiality is the case that matters most here, because getting it wrong in the cheap direction ships a real defect labelled as a nit.
10. Escalate only genuinely ambiguous findings:
   - a Fix that would materially expand the contract by adding a new guarantee, threat model, subsystem, abstraction, compatibility surface, state machine, continuous-monitoring requirement, generalized framework, or broader architecture not required by the accepted intent
   - a product or architecture call not settled by accepted intent
   - repetition that has become evidence, meaning the recurring findings show the accepted product or architecture contract is genuinely ambiguous, or show the abstraction itself needs a new captain-owned contract rather than another correction
   - destructive, irreversible, and genuinely security-sensitive choices, which always escalate under the stronger existing captain boundary
   The third bullet turns on what the repetition PROVES, never on how often it happened.
   Ten findings that each close an independent in-scope defect are ten decisions for firstmate; two that show the abstraction cannot express the accepted contract are an escalation.
   Reaching this step at all means adjudication already ran and the ambiguity survived it, or the finding is a hard safety boundary that was never adjudicable.
11. Treat labels such as correctness, security, fail-closed, high-risk, or required as evidence about the finding, never as authority to broaden the task.

## Approving the review step

`approve` at a no-mistakes review gate means CONTINUE THE PIPELINE despite the findings that remain open.
It does not mean the implementation change is accepted, endorsed, correct, or good, and it never converts an unfixed finding into a settled one.
Reading `approve` as acceptance is what lets a material defect leave the gate: the step advances, the summary says the round was accepted, and nothing records that a real defect was waved through.

Approve only when BOTH of these hold:

1. Every finding you classified as material has been fixed, and the fix is in the head the pipeline will carry forward.
2. Every remaining finding has a recorded per-finding dismissal under step 7, and the set of them passes the smell test below.

The smell test is a deliberate second look at the dismissals TOGETHER, not one at a time.
Read them as a set and ask three questions.
Would a competent reviewer, seeing only the shipped diff and these recorded rationales, agree that nothing consequential was waved through?
Does any single rationale rest on the reviewer being wrong without evidence that they are?
Do the dismissals as a group read as a pattern of avoidance - the same reasoning reused, or the count rising as the run gets longer - rather than as independent judgments about independent findings?
Any yes to the second or third question, or any no to the first, fails the smell test.
A failed smell test is not a reason to approve anyway and note the doubt; go back to step 3 for the findings the doubt attaches to, and adjudicate under step 9 if their materiality is what you are unsure of.

Never approve to escape a long run, a rising round count, or an exhausted fix budget.
Those are budget events with their own handling in step 9, and none of them makes an unfixed material defect immaterial.

## Captain-facing escalation

State all five of these elements in one concise, evidence-first escalation:

1. The original requirement or accepted task criterion.
2. The proposed product or engineering contract expansion.
3. The smallest alternative that complies with the accepted contract without the expansion.
4. The concrete consequences of accepting and declining the expansion.
5. A recommendation with the reason it best serves the accepted intent.

Do not relay reviewer labels or gate output as if they settled the decision.

## Reporting dispositions

Any report of a validation round - to the captain, into a durable outcome record, or into a task status log - says what is being FIXED and what is being DISMISSED, and why, in the captain's outcome language.
Name the material findings being fixed and what each one would have broken, then name each dismissal with the ground it rests on.
When the list is long, group the dismissals by ground and give the count per ground; grouping by a stated ground is still a disposition, and a bare count is not.
Never report a round with a blanket disposition phrase such as "accept none", "accept all", "accepted the round", or "no material findings" offered without the classification that established it.
Those phrases read as a verdict while carrying no evidence, and they are indistinguishable from never having looked.

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
- A test that would pass with the behavior it names removed is a test-integrity defect and is fixed, however small the reviewer said it was.
- A PR body or attestation describing a head that is not the head being shipped is a provenance defect and is fixed, not dismissed as documentation polish.
- A naming or formatting preference with no consequence in any material class is dismissed with that stated, and the run continues.
- A finding whose materiality you genuinely cannot determine from the code and the accepted contract is adjudicated before it is dispositioned, never dismissed as a nit because the fix looked expensive.
