# The dashboard client

The React client for Firstmate's local control-plane dashboard.
It is a read-only view: it never prompts, steers, merges, or controls anything, and it never reads a filesystem path - it calls the versioned API described in [../docs/dashboard.md](../docs/dashboard.md).

## Build

The built bundle in `../assets/dashboard/` is **committed**, so a fresh machine and CI can serve the dashboard with no network and no install step.
The toolchain here is a development convenience, never a runtime or CI dependency.

```bash
bun install --cwd ui                   # once, for development
bin/fm-dashboard-build.sh build        # rebuild the committed bundle
bin/fm-dashboard-build.sh verify       # what startup checks before printing a URL
bin/fm-dashboard-build.sh watch        # rebuild on change
```

`bin/fm-dashboard-build.sh` is the only entry point; run it from the repository root.
Without a toolchain it verifies the committed bundle instead of failing, because a machine that cannot build can still serve.

## Constraints this client works under

- **Flat asset names.** The server serves assets by exact basename from a small extension allowlist, with no subdirectory, so `vite.config.ts` pins `app.js` and `app.css` rather than hashed paths. Changing those names breaks serving.
- **Nothing remote.** No CDN, font, or runtime fetch outside the API. Everything ships in the bundle.
- **Unavailable stays unavailable.** A value this home cannot support is rendered as unavailable with its reason, never as a zero, a dash, or an estimate.
- **Report bodies are data.** They are rendered into React elements, never as markup.

Components come from shadcn/ui (`src/components/ui`); `src/views` holds the screens and `src/lib` the API client, types, and formatting.
