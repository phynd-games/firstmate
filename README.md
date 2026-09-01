# Phynd Firstmate

Phynd Firstmate is the operational agent layer for the Phynd product team.
It provides one captain-facing Pi session, isolated worker sessions, durable supervision, and visible Herdr workspaces.

## Canonical product workspace

Build and evolve the product in the Phynd Cloud monorepo:

<https://github.com/phynd-games/phynd-cloud>

The normal local checkout is `/Users/criz/RizDevDrive/phynd-cloud`.
Read that repository's root `AGENTS.md` and the most specific app guidance before working.

- Rust is used for Lambda workloads where the owning app specifies Rust.
- Each API route is its own Lambda with its own least-privilege AWS IAM policy.
- Do not combine routes or broaden IAM policies without explicit architecture approval.
- Flagship TV is Solid JavaScript.
- Mobile is Expo with React Native.
- Use Sandcastle from Matt Pocock for isolated agent execution when available.
- Select model and harness combinations that preserve local tool access and comply with provider terms of service.

## Get started

### Requirements

- macOS or Linux.
- Git and authenticated GitHub CLI access.
- Node.js and npm.
- Docker or another supported Sandcastle sandbox provider.

### Install and launch

```sh
gh auth login
git clone https://github.com/phynd-games/firstmate
cd firstmate
bin/fm-setup-phynd.sh
herdr
# In the Herdr terminal, from this directory:
pi
```

The setup script:

1. Installs or updates Herdr with the official installer to the latest available release at or above `0.8.0`.
2. Installs Pi when it is missing.
3. Installs the configured Pi packages, including `awesome-pi-themes`.
4. Applies the checked-in Pi defaults after Pi installation.
5. Selects Herdr as the Firstmate backend.
6. Enables one visible Herdr presentation workspace per task.
7. Clones and registers `phynd-games/phynd-cloud` under `projects/phynd-cloud` when it is absent.
8. Initializes the project's no-mistakes gate when a fresh clone and the command are available.

Run `herdr` from the Firstmate directory, then launch `pi` inside the Herdr terminal so the captain and visible workers share the Herdr session.
Approve the project trust prompt when Pi starts so the tracked Firstmate extensions load.
The script does not modify Pi credentials or authentication files.
Set `PHYND_PROJECT_DIR` to use another existing Phynd Cloud checkout path.
The setup never overwrites an existing path that is not a Git checkout.

## Default configuration

[`defaults/pi-settings.json`](defaults/pi-settings.json) is the single canonical Pi captain startup profile.
Tracked [`.pi/settings.json`](.pi/settings.json) is a relative symlink to that file, so plain Pi startup in a trusted Firstmate clone imports the canonical profile before model selection instead of consulting an independent project-local authority.
Workstation setup shallow-merges that same canonical file into global Pi settings, preserving unrelated global keys while installing its theme and packages.
Open TUI defaults and the Claude concise prompt remain separate in `defaults/pi-open-tui.json` and `defaults/phynd-concise.md`.

| Purpose | Default |
| --- | --- |
| Captain harness | Pi |
| Captain model | `openai-codex/gpt-5.6-sol` |
| Captain thinking | `medium` |
| Runtime backend | Herdr |
| Herdr visibility | One presentation workspace per task |
| Pi theme | `cosmic-lagoon` |
| Pi packages | `pi-web-access`, `awesome-pi-themes`, `pi-spark`, `pi-open-tui` |
| Cheap code | Pi + Luna xhigh |
| Feature design / architecture | Claude Code + Fable high |
| Hard code | Pi + Sol high, or Claude Code + Fable xhigh |
| Visible output | Concise by default, without reducing reasoning or verification depth |

Opinionated Phynd fleet routing is checked in under `config/crew-dispatch.json`.
Opinionated runtime selection is checked in under `config/backend` and `config/herdr-presentation-spaces`.
Other operational state under `config/`, `data/`, and `state/` remains local and ignored.

## Working model

Talk only to the captain session.
The captain dispatches implementation, design, investigation, and review work to isolated workers.
Workers use separate git worktrees and appear in Herdr as visible task workspaces.
Never merge a pull request without the captain's explicit approval.

Useful commands inside the Firstmate checkout:

```sh
bin/fm-session-start.sh
bin/fm-setup-phynd.sh
bin/fm-peek.sh <task-id>
```

## Documentation

- [Configuration](docs/configuration.md)
- [Phynd governance skill](.agents/skills/phynd-governance/SKILL.md)
- [Herdr backend](docs/herdr-backend.md)
- [tmux backend](docs/tmux-backend.md)
- [Zellij backend](docs/zellij-backend.md)
- [Orca backend](docs/orca-backend.md)
- [cmux backend](docs/cmux-backend.md)
- [Remote secondmates](docs/remote-secondmates.md)
- [Away-mode alarm](docs/wedge-alarm.md)
- [Architecture](docs/architecture.md)
- [Scripts](docs/scripts.md)
- [Contributing](CONTRIBUTING.md)
- [Always-loaded operating contract](AGENTS.md)
- [Documentation audiences](docs/documentation-audiences.md)

## License

MIT - see [LICENSE](LICENSE).
