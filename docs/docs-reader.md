# Local document reader

Firstmate serves the Markdown under a home's `data/` directory as a formatted, navigable site on the loopback interface, so a report link the captain receives opens as a readable page.
`bin/fm-docs-reader.sh` owns the reader; its header is the authoritative description of every command, record, and tuning variable, and this page only routes an operator to it.

## What it is

The reader is MkDocs running its own development server with its own search, live reload, and bundled theme.
Firstmate contributes a generated private configuration, one hook module, `bin/fm-docs-reader-hooks.py`, that narrows the site and sanitizes each page, and a theme override in `defaults/docs-reader-theme/` that replaces the bundled theme's navigation and page layout.
There is no dashboard, no task control, and no editing surface: the reader reads `data/` and writes only under `state/docs-reader/`.

## Navigation and layout

A home has one directory per task under `data/`, so the site has one navigation section per task and that count only grows.
The bundled theme rendered every section into one horizontal top bar with dropdowns, which with a real inventory grew taller than the browser window: the sticky bar covered every document at 100% zoom, and at 200% zoom the collapsed menu filled the whole window and needed thousands of pixels of scrolling.
The override renders the same navigation as a vertical document tree beside the page: each section is a native disclosure (`<details>`) that opens and closes with the mouse or Enter and Space, the section holding the current page starts open and scrolled into view, and the tree scrolls on its own so a long inventory never grows the page.
Below 992 CSS pixels wide, which is a phone or a desktop window at 200% zoom, the tree becomes a "Documents" panel that opens from the top bar, scrolls independently, closes on Escape or its close button, and hands focus back to the button that opened it.
The document sits in a bounded reading column with a coherent heading scale, and an "On this page" outline of its headings sits beside it on wide windows and folds above it on narrower ones.
The bundled light and dark modes keep working, with a dark code-highlighting stylesheet generated locally from Pygments for the dark mode.
`tests/fm-docs-reader.test.sh` proves the served navigation shape at a 150-section inventory, and `tests/fm-docs-reader-layout.test.sh` drives a real headless Chrome through `chrome-devtools-axi` at desktop, 200%-equivalent, and phone-width viewports to prove the header stays slim, the document stays hit-testable, the panel scrolls, closes on Escape, returns focus, and follows a deep link, skipping itself where that tool is absent.

Blume, the tool first proposed for this reader, was probed and rejected on concrete blockers rather than taste: its dev server rendered `<script>` and event-handler HTML from `.md` report text with no sanitizer hook, followed a symlinked `.md` to content outside the content root, executed `meta.ts` found under the content root, resolved relative `.md` links to its raw-Markdown endpoint instead of the rendered page, and needed a 1033-package install with a 1.2 GB resident dev server.
MkDocs with nh3 and Pygments is 18 pinned packages and roughly 60 MB resident, and every one of those behaviors is covered by `tests/fm-docs-reader.test.sh`.

## Guarantees

- Loopback only: the server binds `127.0.0.1` and nothing else, and there is no host option.
- Only Markdown pages and raster images (`.png`, `.jpg`, `.jpeg`, `.gif`, `.webp`) whose real path is inside the real `data/` directory are served; any symlinked path component, hidden directory, or other file type is absent from the site.
- Report text is data: script and style elements, event-handler attributes, `javascript:` and `data:` URLs, iframes, and remote image sources are removed before a page renders, while headings and their permalink anchors, tables, code blocks with highlighting, and safe inline HTML survive.
- No external requests from rendering: the bundled theme runs with its remote highlight.js disabled, no analytics, no fonts fetched, and highlighting served from a generated local Pygments stylesheet.
- Live updates: creating, editing, renaming, or deleting a Markdown file anywhere under `data/`, including in a new folder, updates the pages and navigation without a restart, and the browser reloads on its own.
- Stable per-file URLs: `data/<dir>/<name>.md` is `/<dir>/<name>/`, and `index.md` or `README.md` is its directory's URL, so relative `.md` links and `#anchors` between reports work.
- No writes into `data/`: the configuration, theme override, runtime, and log live under `state/docs-reader/`, and the built site lives in a private temporary directory.
- Nothing unidentified is ever stopped: the reader signals only a process it can prove is its own MkDocs server for this home.
- Updates converge in place: `ensure` re-copies the tracked theme override and regenerates the configuration only when their content changed, and the configuration carries a digest of the override, so a running reader rebuilds with a new override on its own instead of needing a restart.

## Runtime and installation

The runtime is Python 3.10 or newer with `mkdocs`, `nh3`, and `pygments`.
Two supported ways provide it:

- The Nix developer environment (`./phynd-dev install`) ships a Python with those packages pinned by `flake.lock` (`nix/home.nix`).
- `bin/fm-setup-phynd.sh`, or `bin/fm-docs-reader.sh install` by hand, builds a private venv under `state/docs-reader/venv` from `defaults/docs-reader-requirements.txt`, where every release is pinned with the sha256 digests PyPI publishes, so the install is reproducible and never an unpinned download at startup.

When neither is present the reader reports itself unavailable and Firstmate gives file paths instead of links; nothing else degrades.

## Operating it

Session start runs one bounded `bin/fm-docs-reader.sh ensure` when it holds the fleet lock and prints a single `DOCS_READER:` line: a verified URL, or the reason none could be verified.
That same `ensure` is how a Firstmate update reaches a reader that is already running: it converges the generated configuration and theme override under `state/docs-reader/` and the live server rebuilds, so no `stop` is needed.
`bin/fm-docs-reader.sh url <path>[#anchor]` prints the verified page URL for one Markdown file under `data/`, starting the reader if needed, and exits non-zero with the reason otherwise; Firstmate uses it for every captain-facing document link.
`status` reports without starting anything, and `stop` stops this home's recorded reader.
Write `off` to `config/docs-reader` to turn the reader off for a home.
Each home gets its own reader, port, and records, so several homes on one machine never share a site.

The URL is a loopback address on the captain's machine.
It is meaningful only in the captain's own local session and must never be sent to a Relay reader or any other remote surface.
