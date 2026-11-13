# Relay


Full detail for [AGENTS.md section 14](../../AGENTS.md#14-relay).
The Rules in that section are the load-bearing subset that stays inline; this document owns the detail and is read on demand.

## Rules

- [Activation](#activation): Relay ships inert until the home opts in, and the token is consent for public replies and reversible actions only.
- [Wakes and follow-ups](#wakes-and-follow-ups): load `fmx-respond` on a mention, a configuration blocker, or a Relay-linked terminal outcome.
- [Promised final replies](#promised-final-replies): a promised final public reply is durable state, and only the home holding the consent and thread binding posts it.

## Activation

Relay is the public-mention integration older docs and some emitted lines still call "X mode"; its identifiers keep the `FMX_`, `x-`, and `fm-x-` spellings.
Relay ships inert and causes no behavior change until the home opts in by placing `FMX_PAIRING_TOKEN` in its gitignored `.env`.
That token is consent for public replies and normal reversible lifecycle actions from eligible mentions, not authority for destructive, irreversible, or security-sensitive action; those still require trusted-channel confirmation.
`docs/configuration.md` owns activation, generated state, cadence, wire protocol, and opt-out mechanics.

## Wakes and follow-ups

A Relay-only home still requires the live supervision cycle so mentions can wake it without fleet work.
On an `x-mention <request_id>` or `x-mode-error ...` check wake, load `fmx-respond`, which owns classification, public-safety policy, reply or dismissal, task linking, and follow-ups.
For every Relay-linked terminal outcome, load that owner and use the promised-final reconciliation when a typed public commitment exists, otherwise post the final completion follow-up before teardown.

## Promised final replies

A promised final public reply is durable state, never conversation memory.
Load `fmx-respond` before promising one, on a `public-followup ...` check wake, and whenever the session-start digest lists a public commitment awaiting delivery or an open public loop.
Only the home holding the relay consent and thread binding ever posts it, so never ask a secondmate or crewmate to find the thread or send the reply, and never recover a terminal result by reading a `done:` sentence.
