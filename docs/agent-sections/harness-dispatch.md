# Harness and runtime dispatch


Full detail for [AGENTS.md section 4](../../AGENTS.md#4-harness-and-runtime-dispatch).
The Rules in that section are the load-bearing subset that stays inline; this document owns the detail and is read on demand.

## Rules

- [Harness verification and static resolution](#harness-verification-and-static-resolution): load `harness-adapters` before every spawn or recovery; never dispatch on an unverified adapter.
- [Dispatch-profile resolution](#dispatch-profile-resolution): precedence, the quota-informed choice among a matched profile array, and the effort fallback.
- [Backend and secondmate pins](#backend-and-secondmate-pins): dispatch only on Herdr, and a missing dependency or refused identity is a blocker to surface.

## Harness verification and static resolution

Load `harness-adapters` before every spawn or recovery and before trust handling, skill invocation, interrupt, exit, resume, or adapter verification.
The verified harnesses are `claude`, `codex`, `opencode`, `pi`, `pi-signed`, `grok`, `kimi`, and `cursor`, plus `muse` for crewmates and scouts only; never dispatch on an unverified adapter.
If static `config/crew-harness` or `config/secondmate-harness` names an unverified adapter, report it and fall back only to a verified adapter rather than launching it.

## Dispatch-profile resolution

`docs/configuration.md` owns dispatch-profile and runtime-backend schemas, `bin/fm-harness.sh` owns static resolution, and `bin/fm-spawn.sh` owns launch flags and fail-closed validation.
When dispatch profiles exist, consult them at every crewmate or scout intake and pass the resolved concrete profile required by `fm-spawn`.
Routing precedence is an explicit per-task captain override, then the best-fit configured rule, then the configured default, then the static crewmate harness.
Firstmate alone resolves a matched profile array: begin with `quota-axi`'s default TOON at that intake, using the skill's narrow TOON-then-`--json` fallback only for genuine ambiguity, evaluate every configured candidate against that current output, and choose with inspectable `spendPriority` as the one quota-perspective ranker after the skill's eligibility, reasoning-class, and runway-feasibility gates.
Account for every candidate with the catalog evidence, provider relationship, applicable quota and authentication facts, remaining uncertainty, fit and reasoning class, and the spendPriority and runway evidence used in selection; never omit a candidate, guess, fall back silently, or call the result quota-informed without them.
Establish model support and provider family from that harness's own authoritative catalog, then read `quota-axi` at the granularity the vendor actually supplies: provider-level or all-model evidence applies to every model established in that family, and a named-model window bounds only that model.
Missing model-level quota, a missing authentication source, unmeasurable headroom, or unmodeled authentication is disclosed uncertainty that keeps a candidate eligible, never a credential or login escalation.
Only concrete contradictory evidence blocks a candidate, such as an authoritative catalog proving the model unsupported or proof that the credential selected for that surface is unusable; never infer a credential store, provider family, or quota mapping from a harness, model, or source name, and never launch another harness's CLI to judge a candidate.
Preserve malformed profile configuration as an actionable error rather than selecting around it.
When every candidate is tight, preserve the captain's strongest-reasoning class rather than silently downgrading it solely to conserve quota; stop and report the tight choice if that class cannot proceed.
Break genuine evidence ties without array-order or harness bias.
`quota-axi` owns how model or product windows relate to bounding account windows and remains data-only.
Load `quota-array-dispatch` before choosing among a matched profile array; that skill is the single owner of the TOON-first spendPriority selection procedure.
The generic effort fallback and its precedence are owned by `harness-adapters`: explicit captain and standing configured effort win; otherwise use low for well-understood explicit work, xhigh for ambiguous investigation or design, intermediate levels proportionally, and never max without explicit captain preference.
Do not add model-specific versions of that policy.

## Backend and secondmate pins

`secondmate-provisioning` owns secondmate harness pins and inherited local material, while `harness-adapters` owns the harness consequences.
Dispatch only on Herdr, the one backend `fm-spawn` validates as spawn-capable under hard rule 6; an explicit per-spawn `--backend` may only restate `herdr` and is passed only under that exact task's own authority, never as later-task precedent (selection contract: [`docs/configuration.md`](../configuration.md) "Runtime backend").
A missing dependency, authentication failure, refused backend identity, or version refusal is a blocker to surface; there is no other backend to retry on.
