# Instruction-source verification

Audience: maintainer verification.

This record owns current evidence for Firstmate's one-source instruction and skill layout.

## Canonical layout

Verified 2026-08-31 on macOS with Claude Code 2.1.251, Pi 0.84.4, Herdr 0.8.2, and tmux 3.7b.

`.agents/skills/` is the only editable source for agent-loaded Firstmate skills.

`.claude/skills` and `.grok/skills` are tracked symlinks to `../.agents/skills`.

`AGENTS.md` is the only Firstmate policy source.

`CLAUDE.md` is a two-line real file using Claude Code's supported `@AGENTS.md` import.

`GROK_BOT.md` is only a four-line Grok Bot bootstrap adapter that tells the operator to attach `AGENTS.md`.

`skills/` remains a separate public installer surface and is not an agent-loaded skill source.

The executable invariant is owned by `bin/fm-instruction-sources-check.sh`.

## Vendor behavior

Claude Code 2.1.251 was inspected with `claude --help`.

The installed help identifies `CLAUDE.md` auto-discovery and provides `--system-prompt-file` and `--append-system-prompt-file` for explicit prompt files.

Claude's supported project-memory import syntax is documented at [How Claude remembers your project](https://code.claude.com/docs/en/memory).

That documentation specifies `@path/to/file` imports in `CLAUDE.md`, including `@AGENTS.md`.

Grok Build's current project-rules documentation lists `AGENTS.md`, `Agents.md`, `AGENT.md`, `Claude.md`, `CLAUDE.md`, and `CLAUDE.local.md` as recognized files, but does not list `GROK_BOT.md`.

Grok Build's documented skill roots include `.grok/skills/`, so the tracked symlink exposes the canonical source without copying it.

Grok Bot's current collaboration documentation supports attaching local files to a Bot profile, but does not document repository instruction-file imports or automatic loading of `GROK_BOT.md`.

`GROK_BOT.md` therefore uses attachment guidance rather than an invented import token or a duplicate policy copy.

Sources: [Grok Build project rules](https://docs.x.ai/build/features/project-rules), [Grok Build skills and plugins](https://docs.x.ai/build/features/skills-plugins-marketplaces), and [Grok Bot collaboration](https://docs.x.ai/grok-bot/chat-and-collaboration).

No `grok` executable was installed in this validation environment, so Grok Build behavior was not live-probed.

## Regression commands

```sh
bin/fm-instruction-sources-check.sh
bin/fm-test-run.sh tests/fm-instruction-sources.test.sh
bin/fm-doc-audience-check.sh
```

Observed output:

```text
fm-instruction-sources-check: ok canonical=.agents/skills claude=pointer grok=attachment-adapter
ok - canonical skill source and Claude/Grok instruction bridges pass
ok - duplicate Grok skill directory is rejected
ok - dangling Claude skill bridge is rejected
ok - duplicated Grok instruction policy is rejected
ok - dangling Claude instruction import is rejected
```

The regression fixture deliberately replaces each bridge with a duplicate or dangling entrypoint and requires the checker to reject it.

The check is also called by the CI repository-invariants job and by the contributor smoke path.
