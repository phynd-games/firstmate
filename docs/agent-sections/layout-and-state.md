# Layout and state


Full detail for [AGENTS.md section 2](../../AGENTS.md#2-layout-and-state).
The Rules in that section are the load-bearing subset that stays inline; this document owns the detail and is read on demand.

## Rules

- [Layout ownership](#layout-ownership): `docs/configuration.md` owns the top-level layout and configuration schemas, and `FM_HOME` selects an instance's private directories.
- [The layout tree](#the-layout-tree): every tracked path, private directory, and `state/` record, with the script that owns it.
- [Status lines and captain records](#status-lines-and-captain-records): a status line is a wake event, not current-state truth, and `data/captain.md`, `data/captain-shared.md`, and `data/learnings.md` stay canonical.

## Layout ownership

`docs/configuration.md` is the single owner of the top-level operational-home layout and configuration schemas; each producing script's header and help own exact child fields and mutation mechanics.
`FM_HOME` selects an instance's private `data/`, `state/`, `config/`, and `projects/`, while scripts continue to come from their tracked code root.
In the locked mutable primary bootstrap path, a missing `config/backend` is materialized exactly as `herdr\n`; existing files are never overwritten, and detect-only or unlocked paths do not materialize it.
Each secondmate has a persistent isolated `FM_HOME`, including its own state, backlog, projects, and session lock.
`bin/fm-send.sh` fails closed unless `FM_HOME` is explicit, so a steer cannot silently resolve against another home.

Tracked files hold shared instructions and tooling; `data/` holds durable private fleet records; `state/` holds runtime records and append-only status events; `config/` holds checked-in Phynd defaults and local operating choices; and `projects/` contains clones that are read-only to firstmate except under hard rule 1's concrete captain-approved project operation exception.

## The layout tree

```
AGENTS.md            this file (CLAUDE.md is a real @AGENTS.md pointer to it)
CONTRIBUTING.md      contributor workflow and repo conventions
README.md            public overview and development notes
.github/workflows/   shared CI, committed; ci.yml owns hosted execution policy and exclusions
.tasks.toml          tracked tasks-axi markdown backend config for the default backlog backend (section 10)
.agents/skills/      firstmate-loaded internal skills, committed; each carries metadata.internal=true for installers
.claude/skills       symlink to .agents/skills for Claude Code compatibility
.grok/skills         symlink to .agents/skills for Grok Build compatibility
skills/              standalone public installer-facing skills, committed; not loaded by firstmate
bin/                 helper scripts, committed; read each script's header before first use
.env                 optional Relay pairing token; LOCAL, gitignored; presence-gates section 14
config/crew-harness  crewmate harness override; LOCAL, gitignored; absent or "default" = same as firstmate. Inherited as the literal file: a concrete primary adapter value also controls a secondmate home's own crewmates (section 4)
config/crew-dispatch.json  tracked Phynd crewmate dispatch profiles; opinionated but human-editable natural-language rules that choose a per-task harness/model/effort profile (section 4). Inherited by secondmate homes
config/secondmate-harness  harness the PRIMARY uses to launch SECONDMATE agents, optionally followed by a model and effort token on the same line ("<harness> [<model>] [<effort>]"; section 4); LOCAL, gitignored; absent or "default" harness falls back to config/crew-harness then firstmate's own. The primary's own setting; NOT inherited into secondmate homes (secondmates do not spawn secondmates)
config/backlog-backend  backlog backend override; LOCAL, gitignored; absent or "tasks-axi" = default tasks-axi backend, "manual" = force routine backlog updates to hand-editing; inherited by secondmate homes (section 10)
config/backend  tracked Phynd runtime session-provider backend declaration; Phynd setup writes `herdr`, the only accepted value (hard rule 6); absent, empty, or any other value refuses every spawn and the session-start bootstrap by name with the Herdr remediation, and nothing is ever auto-detected from runtime markers (docs/configuration.md "Runtime backend"; docs/herdr-backend.md); tmux, zellij, orca, and cmux are retained legacy adapters unreachable for the active runtime, and codex-app is not accepted (docs/codex-app-backend.md); inherited by secondmate homes under the primary-authoritative contract in secondmate-provisioning
config/calm     Pi Calm presentation preference; LOCAL, gitignored, and not inherited; see docs/configuration.md "Pi Calm preference"
config/supervision-branch-model config/supervision-branch-effort  Pi supervision-branch model and reasoning-effort pins written by /supervision-model; LOCAL, gitignored, independently settable, and not inherited; see docs/configuration.md "Pi supervision branch model and effort"
config/startup-memory-budget     primary-authoritative per-home startup-memory budget; LOCAL, gitignored, materialized as 7,500 estimated tokens by locked primary bootstrap and inherited into secondmate homes; see docs/configuration.md "Startup memory budget"
config/stow-pass-horizon  optional presence flag opting this home in to /stow's default-off pass-count decay horizon; LOCAL, gitignored, and not inherited; see docs/configuration.md "Stow pass horizon"
config/herdr-presentation-spaces  tracked Phynd setting for Herdr's disposable single-task visual projection; Phynd setup writes `on`; inherited by secondmate homes; see docs/herdr-backend.md "Presentation spaces"
config/herdr-supervisor  optional selector for hosting this home's watcher continuity in a Herdr-tracked pane when the primary harness never loaded its own owner; LOCAL, gitignored; absent or `auto` covers a Pi primary whose extension is provably not loaded, `on` covers any harness, `off` disables it; inherited by secondmate homes; see docs/herdr-supervisor.md
config/trace-context  optional presence flag enabling default-off native W3C trace-context propagation to spawned agents; LOCAL, gitignored; inherited by secondmate homes; see docs/configuration.md "Trace context propagation" and docs/trace-context.md
config/cmux-socket-password  retained historical cmux control-socket password setting; LOCAL, gitignored, ignored by the active Herdr-only runtime, and non-operational (docs/cmux-backend.md)
config/wedge-alarm  optional away-mode wedge-alarm active-alert directives; LOCAL, gitignored; absent means auto (macOS Notification Center when available); see docs/wedge-alarm.md
config/docs-reader  optional `off` switch for this home's local Markdown document reader; LOCAL, gitignored, not inherited; see docs/docs-reader.md
bin/fm-setup-phynd.sh  engineer workstation setup: installs Pi, installs configured Pi packages, and applies the checked-in Phynd Pi defaults
config/watched-tools.json  optional list of the tools this home depends on, read by the update check armed with bin/fm-tool-update-check.sh; LOCAL, gitignored, firstmate-maintained but human-editable, and NOT inherited by secondmate homes; see docs/configuration.md "Watched tool updates"
config/x-mode.env    generated Relay watcher cadence; LOCAL, gitignored; source before arming watcher when present
data/                personal fleet records; LOCAL, gitignored as a whole
  backlog.md         task queue, dependencies, history
  captain.md         this home's domain-local captain preferences and working style; LOCAL, gitignored, canonical even if harness memory mirrors it, and updated with inspect-then-update
  captain-shared.md  main-authoritative shared captain preferences propagated read-only to secondmate homes; LOCAL, gitignored, owned by secondmate-provisioning
  learnings.md       fleet-local operational facts and gotchas; LOCAL, gitignored; dated, evidence-backed, curated, and updated with inspect-then-update - rewrite and prune rather than append forever, the same contract as captain.md; created lazily, absent until this home has a learning to store
  projects.md        thin fleet navigation registry recording each project's standing delivery posture; firstmate-private, parsed for mechanical sync and seeding by fm-project-mode.sh (section 6)
  secondmates.md      local and remote secondmate routing table; firstmate-private, maintained by the secondmate seed helpers (section 6)
  <id>/brief.md      per-task crewmate brief, or per-secondmate charter brief when kind=secondmate
  <id>/report.md     scout task deliverable, written by the crewmate; survives teardown
projects/            cloned repos; gitignored; read-only except under hard rule 1's concrete captain-approved project operation exception
state/               runtime records and signals; gitignored
  <id>.status        appended by crewmates: "<state>: <note>" wake-event lines, not current-state truth
  <id>.turn-ended    touched by turn-end hooks
  <id>.grok-turnend-token   firstmate-owned grok hook registry token for the task; removed by teardown
  <id>.kimi-turnend-token   firstmate-owned Kimi hook registry token for the task; removed by teardown
  <id>.muse-session  muse busy-source binding (sessions root plus task worktree) written by fm-spawn; removed by teardown
  <id>.cursor-session  cursor busy-source binding (projects root, task worktree, prior conversations) written by fm-spawn; removed by teardown
  <id>.reconcile-nudged  epoch second of the last inventory-reconcile nudge sent to this secondmate; bin/fm-secondmate-reconcile.sh owns its per-home cooldown window
  <id>.handoff/        per-instruction handoff obligations and their verdicts: whether the worker acknowledged that exact steering record and the work observably started; written only by bin/fm-handoff-confirm.sh, removed by teardown
  <id>.backlog-close  the exact backlog close a teardown recorded before removing the task's record, so an interrupted cleanup can still be finished at the next session start; bin/fm-backlog-transition-lib.sh owns its format and replay, and a landed close removes it
  <id>.inbox/          durable steering inbox: sequenced firstmate instruction records the worker acknowledges by moving them into its handled/ subdirectory; written by fm-send, with ordinary records re-rung and escalated by the watcher while explicit fire-and-forget records are excluded from that ladder, and removed by teardown (bin/fm-task-inbox-lib.sh)
  <id>.meta          task metadata; each producer script's header owns its exact fields and mutation contract, with docs/configuration.md routing operator-facing backend and trace-context details
  <id>.validation-loop  durable validation-loop journal bounding automatic validation continuation; bin/fm-validation-loop-lib.sh owns the contract and thresholds; removed by teardown
  .branch-note-sig-*  per-task last-rendered routine branch-note novelty signature powering deterministic duplicate coalescing; bin/fm-branch-outcome.sh's note-render header owns it; removed by teardown
  <id>.lavish-intake  hash-bound Lavish intake receipt; removed by teardown after landing
  <id>.lavish-intake-session <id>.lavish-intake-classification  active intake binding or explicit exemption marker; removed by teardown
  <id>.herdr-presentation  quarantinable attempt and restart-binding journal for Herdr's optional visual projection; never task or endpoint authority; see docs/herdr-backend.md "Presentation spaces"
  <id>.launch        task launch accounting; bin/fm-launch-record.py owns the contract and docs/launch-records.md the operator view; removed by teardown
  .launch-<helper>   helper launch accounting; docs/launch-records.md owns coverage and docs/herdr-supervisor.md the supervisor projection exception
  .herdr-supervisor-cleaned.<generation>  supervisor-owned confirmed cleanup receipt retained until its terminal launch projection recovers; see docs/herdr-supervisor.md
  <id>.check.sh      authenticated slow poll; the watcher dispatches validated PR data and the byte-identified Relay shim through trusted repository scripts, runs registered custom checks from hash-validated private snapshots, and rejects every other state check without execution
  <id>.check-trust   private content binding created by fm-check-register.sh for an intentional custom check
  <id>.pr-poll       private validated data sidecar for the byte-static PR merge poll
  <id>.pr-poll-registration  private transactional provenance record binding the task, canonical metadata identity, sidecar, and static poll publication
  <id>.pr-poll-retirement  private identity-bound crash-recovery receipt for one exact validated merged result; removed after its poll artifacts retire
  <id>.pr-poll-merge-notified  canonical PR identity of the last merge outcome delivered for this task; bin/fm-pr-lib.sh owns the marker format and identity mechanics, while bin/fm-merge-outcome-lib.sh owns locked publication, duplicate suppression, and replacement
  branch-outcomes.jsonl .branch-outcomes-cursor  Pi supervision-branch durable outcome store and its read cursor; bin/fm-branch-outcome.sh owns the format
  branch-session/ .branch-session .branch-mirror-cursor  the branch's persistent conversation, its pointer, and the dialog-mirror cursor; extension-owned (docs/pi-supervision-branch.md)
  .branch-eligible-rows .branch-eligible-owner .main-eligible-rows  per-actor wake-row claims and branch-owner evidence; docs/watcher-continuity.md owns the acknowledgement contract
  .lease-<task>        per-task supervision lease naming which actor (main or branch) may change that task; bin/fm-lease-lib.sh owns the contract the guarded scripts enforce
  x-watch.check.sh   generated Relay poll shim; present only when opted in (section 14)
  tool-updates.check.sh  generated watched-tool update poll shim and its .check-trust binding; present only after bin/fm-tool-update-check.sh arm; its report record .tool-updates is what keeps one pending update from being reported on every poll
  pending-replies/   parent-owned secondmate pending-reply records (correlation id, delivery vs reply, recovery, escalation); fm-pending-reply-lib.sh
  procevent/         registered process-to-event sources, one private record per canonical source id; written only by bin/fm-procevent.sh, and their presence alone keeps supervision required (section 13)
  procevent-inbox/   private captured results and their durable handled-acknowledgement markers; source output lives here and never in an event line
  decision-bindings/ private records marking a captured-answer source as feeding the keyed-answer intake, with a legacy origin on pre-collapse records; written only by bin/fm-captain-hold.sh bind, dropped by unbind and by source retirement (section 13; docs/captain-hold-lifecycle.md)
  when/              private condition->action watch specs, their trust bindings, and single-fire markers; written only by bin/fm-procevent-when.sh (section 13's process-event-sources trigger)
  inbox/             captain notes captured out of band by bin/fm-inbox.sh, including the voice handover's queued requests; each note appends one `check` wake and stays pending until acknowledged with `bin/fm-inbox.sh drain --ack <id>`, which moves it to inbox/handled/ (docs/voice-relay.md)
  x-inbox/           generated Relay pending mention payloads; fmx-respond drains it (section 14)
  x-context/         generated Relay durable per-request reply context and one-wake offer markers, keyed by request_id; survives inbox cleanup and expires within seven days (section 14; bin/fm-x-lib.sh)
  x-outbox/          generated Relay dry-run reply and dismiss previews; inspect it when FMX_DRY_RUN is set (section 14)
  public-followup/   generated private transport for promised public replies: retained open-loop registrations, typed terminal-result inbox, accepted/rejected ledgers, and retirement receipts (section 14; bin/fm-public-followup.sh)
  x-poll.error x-poll.claim-error  generated Relay and offer-claim diagnostic dedupe markers
  .startup-network.*  status, report, per-step elapsed timings, inline-print claim, and lock for the deferred network stage session start runs off its blocking path; bin/fm-startup-network.sh
  .docs-reader .docs-reader.lock docs-reader/  the local Markdown document reader's owner record, lock, and generated private runtime (configuration, theme override, venv, log); bin/fm-docs-reader.sh owns them and docs/docs-reader.md owns the operator contract
  .wake-queue        durable queued wakes retained until post-handling acknowledgement: epoch<TAB>seq<TAB>kind<TAB>key<TAB>payload
  .watcher-down      private generation-bound recovery state coupling watcher downtime, durable wake presentation, and post-handling acknowledgement; never touch
  .herdr-supervisor .herdr-supervisor-live .herdr-supervisor-heartbeat .herdr-supervisor-alarm .herdr-supervisor-launch.sh .herdr-supervisor-monitor .herdr-supervisor-monitor-heartbeat .herdr-supervisor.log  Herdr-hosted watcher continuity: the binding record, the loop's own generation and process identity, its liveness beacon, its durable actionable diagnostic, the generated launcher the pane executes, and a bounded diagnostic ledger; bin/fm-herdr-supervisor.sh owns them and docs/herdr-supervisor.md owns the contract
  .<id>.open-decisions-cursor  per-task byte cursor and folded open-decision set bounding the OPEN DECISIONS scan's cost to new status-log appends; written only by fm-classify-lib.sh's status_open_decisions_incremental, removed by teardown, safe to delete (forces one full re-fold)
  .status-presentation-cursor .status-presentation-lock  fleet-wide per-task status identity/byte-offset manifest and serialization lock preventing already-presented status lines from being replayed as new; owned by fm-classify-lib.sh, with each task's row retired by teardown
  .afk               durable away-mode flag; present = sub-supervisor may inject escalations (set by /afk, cleared on user return)
  .watch.lock .wake-queue.lock watcher singleton and queue serialization locks
  .claude-autoarm.lock .claude-autoarm-epoch .claude-autoarm-failure-notified .claude-autoarm-failure-alarmed .turnend-claude-blocks .turnend-claude-blocks.lock   Claude Stop auto-arm single-flight, epoch, failure-episode, attended-alarm, guard-budget, and budget-lock records; never touch
  .cursor-park-owner .cursor-park-owner.lock .turnend-cursor-blocks   Cursor stop-hook owner record, publication and commit lock, and bounded repair-nag budget; never touch
  .hash-* .count-* .stale-* .stale-since-* .churn-since-* .paused-* .wedge-escalations-* .writing-* .seen-* .hb-surfaced-* .last-* .heartbeat-streak .vloop-evidence-*   watcher internals; never touch
  .watch-triage.log  watcher's absorbed-wake debug log (size-capped); never relied on, safe to delete
  .last-watcher-beat watcher liveness beacon, touched every poll (including while absorbing benign wakes); guard scripts read it
  .subsuper-* .supervise-daemon.*   sub-supervisor internals; never touch
.no-mistakes/        local validation state and evidence; gitignored
```

## Status lines and captain records

A `state/<id>.status` line is a wake event, not current-state truth; `bin/fm-crew-state.sh` owns current-state reconciliation.
Treat `data/captain.md` as the domain-local record of captain preferences, optional `data/captain-shared.md` as the main-authoritative shared captain-preference file for secondmate inheritance, and `data/learnings.md` as curated home-local knowledge, regardless of harness memory.
