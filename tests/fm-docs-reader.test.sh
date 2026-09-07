#!/usr/bin/env bash
# Behavior tests for the local Markdown document reader (bin/fm-docs-reader.sh
# with bin/fm-docs-reader-hooks.py).
#
# Every case drives the real server over HTTP against a throwaway home, so the
# contract proven here is what a browser sees: path safety (traversal, symlink
# escape, non-Markdown, outside-home), inert active content, live create/edit/
# rename/delete without a restart, loopback-only binding, per-home isolation,
# idempotent restart-safe startup that never kills an unidentified process, and
# no writes into data/. It needs a runtime that imports mkdocs, nh3, and
# pygments (FM_DOCS_READER_PYTHON, a venv from `install`, or python3); without
# one it prints a gate skip. The opt-in FM_DOCS_READER_INSTALL_TEST=1 case
# exercises the network-dependent pinned install path.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

READER="$ROOT/bin/fm-docs-reader.sh"
TMP_ROOT=$(fm_test_tmproot fm-docs-reader)

# new_home runs inside $(...), so it cannot append to an array in this shell;
# cleanup instead stops every reader whose record lives under TMP_ROOT.
cleanup() {
  local record home
  for record in "$TMP_ROOT"/*/state/.docs-reader; do
    [ -f "$record" ] || continue
    home=${record%/state/.docs-reader}
    FM_HOME="$home" FM_DOCS_READER_TEST_ALLOW=1 "$READER" stop >/dev/null 2>&1 || true
  done
  fm_test_cleanup
}
trap cleanup EXIT INT TERM

export FM_DOCS_READER_TEST_ALLOW=1
export FM_DOCS_READER_READY_SECS=30

if ! RUNTIME_PYTHON=$(FM_HOME="$TMP_ROOT/probe" "$READER" python 2>/dev/null); then
  printf 'skip: docs reader runtime (mkdocs, nh3, pygments) not found\n'
  exit 0
fi
export FM_DOCS_READER_PYTHON="$RUNTIME_PYTHON"

# new_home <name>: a home with fixture Markdown; echoes its path.
new_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/config" "$home/data/nested/deeper" "$home/data/other"
  cat > "$home/data/index.md" <<'EOF'
# Fixture home

See [the nested report](nested/report.md) and [a deep section](nested/deeper/deep.md#second-section).
EOF
  cat > "$home/data/nested/report.md" <<'EOF'
# Nested report

| Col A | Col B |
| --- | --- |
| 1 | two |

```bash
echo "code block"
```

<script>window.__pwned = 1;</script>
<img src="x" onerror="window.__pwned2=1">
<img src="https://example.invalid/leak.png">
<a href="javascript:alert(1)">js link</a>
<iframe src="https://example.invalid/"></iframe>
<style>body{display:none}</style>

Inline <b>bold html</b> and a [back link](../index.md).

## Section two

Anchor target. [Deep link](deeper/deep.md#second-section).
EOF
  cat > "$home/data/nested/deeper/deep.md" <<'EOF'
# Deep file

## First section

## Second section

Text.
EOF
  printf 'PRIVATE-TEXT-MARKER\n' > "$home/data/other/private.txt"
  printf '{"secret":"PRIVATE-JSON-MARKER"}\n' > "$home/data/other/record.json"
  printf '<script>alert(1)</script>\n' > "$home/data/other/page.html"
  printf 'print("META-EXECUTED")\n' > "$home/data/other/meta.py"
  printf '# Outside\n\nOUTSIDE-CONTENT-MARKER\n' > "$TMP_ROOT/outside-$1.md"
  ln -s "$TMP_ROOT/outside-$1.md" "$home/data/escape.md"
  ln -s /etc "$home/data/etc-link"
  mkdir -p "$home/data/.hidden"
  printf '# Hidden\n\nHIDDEN-MARKER\n' > "$home/data/.hidden/note.md"
  printf '%s\n' "$home"
}

reader() {  # <home> <args...>
  local home=$1
  shift
  FM_HOME="$home" "$READER" "$@"
}

ensure_url() {  # <home> - echoes the verified base URL
  local home=$1 line
  line=$(reader "$home" ensure) || fail "ensure failed for $home: $line"
  case "$line" in
    "DOCS_READER: http://127.0.0.1:"*) printf '%s\n' "${line#DOCS_READER: }" ;;
    *) fail "ensure printed no verified URL: $line" ;;
  esac
}

http_code() {  # <url>
  curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$1"
}

http_body() {  # <url>
  curl -s --max-time 5 "$1"
}

# wait_until <seconds> <command...>: poll until the command succeeds.
wait_until() {
  local secs=$1 deadline
  shift
  deadline=$(( $(date +%s) + secs ))
  while [ "$(date +%s)" -le "$deadline" ]; do
    if "$@"; then
      return 0
    fi
    sleep 0.25
  done
  return 1
}

body_has() {  # <url> <needle>
  case "$(http_body "$1")" in
    *"$2"*) return 0 ;;
  esac
  return 1
}

code_is() {  # <url> <code>
  [ "$(http_code "$1")" = "$2" ]
}

test_url_helper_path_safety() {
  local home url out rc
  home=$(new_home safety)
  url=$(reader "$home" url "$home/data/nested/report.md#section-two") \
    || fail "url helper refused a valid nested page"
  case "$url" in
    http://127.0.0.1:*/nested/report/#section-two) ;;
    *) fail "url helper printed an unexpected URL: $url" ;;
  esac
  url=$(reader "$home" url "$home/data/index.md") || fail "url helper refused index.md"
  case "$url" in
    http://127.0.0.1:*/) ;;
    *) fail "index.md did not map to the site root: $url" ;;
  esac
  url=$(reader "$home" url "$home/data/other/../nested/../nested/report.md") \
    || fail "a dotted path that stays inside data/ was refused"
  case "$url" in
    */nested/report/) ;;
    *) fail "dotted in-tree path mapped wrongly: $url" ;;
  esac
  pass "url helper maps nested pages, index, anchors, and in-tree dotted paths"

  out=$(reader "$home" url "$home/data/other/../../state/docs-reader/mkdocs.yml" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "traversal outside data/ was accepted: $out"
  assert_contains "$out" "not a Markdown file" "traversal to a non-Markdown file was not refused by type"
  printf '# Outside md\n' > "$TMP_ROOT/outside-traversal.md"
  out=$(reader "$home" url "$home/data/../../outside-traversal.md" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "traversal to a Markdown file outside data/ was accepted: $out"
  assert_contains "$out" "outside this home" "traversal outside data/ did not name the boundary"
  pass "url helper refuses traversal outside data/"

  out=$(reader "$home" url "$home/data/escape.md" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "symlink escape was accepted: $out"
  assert_contains "$out" "symlinked path component" "symlink escape was refused for the wrong reason: $out"
  pass "url helper refuses a symlink that escapes data/"

  out=$(reader "$home" url "$home/data/other/private.txt" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "non-Markdown file was accepted: $out"
  assert_contains "$out" "not a Markdown file" "non-Markdown refusal did not say so: $out"
  pass "url helper refuses a non-markdown file"

  out=$(reader "$home" url "$TMP_ROOT/outside-safety.md" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "a Markdown file outside the home was accepted: $out"
  assert_contains "$out" "outside this home" "outside-home refusal did not say so: $out"
  out=$(reader "$home" url "$home/data/.hidden/note.md" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "a hidden-directory page was accepted: $out"
  out=$(reader "$home" url "$home/data/nested/missing.md" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "a missing page was accepted: $out"
  pass "url helper refuses outside-home, hidden, and missing paths"
}

test_active_content_is_inert() {
  local home base body
  home=$(new_home active)
  base=$(ensure_url "$home")
  body=$(http_body "$base/nested/report/")
  assert_not_contains "$body" "__pwned" "a script or handler from report text reached the page"
  assert_not_contains "$body" "<script>window" "a script element from report text survived"
  assert_not_contains "$body" "onerror=" "an event handler attribute survived"
  assert_not_contains "$body" "javascript:" "a javascript: URL survived"
  assert_not_contains "$body" "<iframe" "an iframe survived"
  assert_not_contains "$body" "display:none" "a style element from report text survived"
  assert_not_contains "$body" "example.invalid" "a remote image source survived and would fetch externally"
  assert_contains "$body" "<b>bold html</b>" "safe inline HTML was lost"
  assert_contains "$body" 'id="section-two"' "heading anchor ids were lost"
  assert_contains "$body" "<table>" "the table was lost"
  assert_contains "$body" "code block" "the code block was lost"
  pass "active content from report text is inert while headings, tables, and code render"

  body=$(http_body "$base/")
  case "$body" in
    *cdnjs.cloudflare.com*|*googletagmanager*|*google-analytics*|*fonts.googleapis*)
      fail "the theme references an external host: $(printf '%s' "$body" | grep -o 'https\?://[^"/]*' | sort -u | tr '\n' ' ')" ;;
  esac
  pass "active rendering references no external host"

  # The page's own stylesheets and scripts must come from the reader itself:
  # the hooks narrow data/ to Markdown, and that narrowing must never swallow
  # the theme's assets (an unstyled page is what that regression looks like).
  local asset assets missing=''
  assets=$(printf '%s' "$body" | grep -o '<link[^>]*rel="stylesheet"[^>]*>\|<script[^>]*src="[^"]*"' \
    | grep -o 'href="[^"]*"\|src="[^"]*"' | sed 's/^[a-z]*="//; s/"$//')
  [ -n "$assets" ] || fail "the home page declares no stylesheets or scripts"
  for asset in $assets; do
    code_is "$base/${asset#./}" 200 || missing="$missing $asset"
  done
  [ -z "$missing" ] || fail "theme assets are not served (404):$missing"
  code_is "$base/css/codehilite.css" 200 || fail "the generated highlight stylesheet is not served"
  pass "active page assets (theme CSS, JS, highlight stylesheet) are served locally"
}

test_serves_only_markdown_and_images() {
  local home base
  home=$(new_home narrow)
  base=$(ensure_url "$home")
  code_is "$base/nested/report/" 200 || fail "nested page not served"
  code_is "$base/nested/deeper/deep/" 200 || fail "deep page not served"
  code_is "$base/other/private.txt" 404 || fail "a private text file was served"
  code_is "$base/other/record.json" 404 || fail "a private JSON file was served"
  code_is "$base/other/page.html" 404 || fail "a raw HTML file was served"
  code_is "$base/other/meta.py" 404 || fail "a script file was served"
  code_is "$base/escape/" 404 || fail "a symlinked page escaping data/ was served"
  code_is "$base/etc-link/hosts" 404 || fail "a symlinked directory was served"
  code_is "$base/.hidden/note/" 404 || fail "a hidden directory page was served"
  body_has "$base/" "PRIVATE-TEXT-MARKER" && fail "private text leaked into a page"
  body_has "$base/" "HIDDEN-MARKER" && fail "hidden page leaked into navigation"
  body_has "$base/nested/report/" 'href="../deeper/deep/"' \
    || fail "a relative .md link was not rewritten to the rendered page"
  body_has "$base/" 'href="nested/deeper/deep/#second-section"' \
    || fail "a relative .md link with an anchor was not rewritten"
  pass "the site serves only Markdown pages inside data/ and rewrites relative .md links"
}

test_live_updates_without_restart() {
  local home base pid
  home=$(new_home live)
  base=$(ensure_url "$home")
  pid=$(awk -F= '$1 == "pid" {print $2}' "$home/state/.docs-reader")
  mkdir -p "$home/data/brandnew/sub"
  printf '# Brand new\n\nFRESH-CONTENT-1\n' > "$home/data/brandnew/sub/page.md"
  wait_until 20 body_has "$base/brandnew/sub/page/" "FRESH-CONTENT-1" \
    || fail "a newly created nested page did not appear"
  wait_until 20 body_has "$base/" "brandnew/sub/page/" \
    || fail "navigation did not pick up the new page"
  printf '# Brand new\n\nFRESH-CONTENT-2\n' > "$home/data/brandnew/sub/page.md"
  wait_until 20 body_has "$base/brandnew/sub/page/" "FRESH-CONTENT-2" \
    || fail "an edited page did not update"
  mv "$home/data/brandnew/sub/page.md" "$home/data/brandnew/sub/renamed.md"
  wait_until 20 code_is "$base/brandnew/sub/renamed/" 200 || fail "a renamed page did not appear at its new URL"
  wait_until 20 code_is "$base/brandnew/sub/page/" 404 || fail "a renamed page still answers at its old URL"
  rm -r "$home/data/brandnew"
  wait_until 20 code_is "$base/brandnew/sub/renamed/" 404 || fail "a deleted page still answers"
  wait_until 20 body_has "$base/" "brandnew" && fail "navigation still lists the deleted page"
  [ "$(awk -F= '$1 == "pid" {print $2}' "$home/state/.docs-reader")" = "$pid" ] \
    || fail "the reader was restarted during live updates"
  kill -0 "$pid" 2>/dev/null || fail "the reader process died during live updates"
  pass "live create, edit, rename, and delete update pages and navigation without a restart"
}

test_loopback_only_and_isolation() {
  local home_a home_b base_a base_b port_a port_b listeners out rc
  home_a=$(new_home iso-a)
  home_b=$(new_home iso-b)
  printf '# Only in A\n\nONLY-IN-A\n' > "$home_a/data/only-a.md"
  printf '# Only in B\n\nONLY-IN-B\n' > "$home_b/data/only-b.md"
  base_a=$(ensure_url "$home_a")
  base_b=$(ensure_url "$home_b")
  port_a=${base_a##*:}; port_a=${port_a%/}
  port_b=${base_b##*:}; port_b=${port_b%/}
  [ "$port_a" != "$port_b" ] || fail "two homes shared one port"
  listeners=$(lsof -nP -iTCP:"$port_a" -sTCP:LISTEN 2>/dev/null | awk 'NR > 1 {print $9}')
  [ -n "$listeners" ] || fail "no listener found on $port_a"
  case "$listeners" in
    *'*:'*|*'[::]'*|*0.0.0.0*) fail "reader is not loopback-only: $listeners" ;;
  esac
  assert_contains "$listeners" "127.0.0.1:$port_a" "listener is not on 127.0.0.1: $listeners"
  pass "the reader binds loopback only"
  body_has "$base_a/only-a/" "ONLY-IN-A" || fail "home A does not serve its own page"
  code_is "$base_a/only-b/" 404 || fail "home A served home B's page"
  body_has "$base_b/only-b/" "ONLY-IN-B" || fail "home B does not serve its own page"
  code_is "$base_b/only-a/" 404 || fail "home B served home A's page"
  out=$(reader "$home_a" url "$home_b/data/only-b.md" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "home A's url helper accepted a page from home B: $out"
  pass "two homes get distinct ports and isolation of their documents"
}

test_ensure_is_idempotent_and_restart_safe() {
  local home base pid pid2 line sleeper
  home=$(new_home restart)
  base=$(ensure_url "$home")
  pid=$(awk -F= '$1 == "pid" {print $2}' "$home/state/.docs-reader")
  [ "$(ensure_url "$home")" = "$base" ] || fail "a second ensure changed the URL"
  pid2=$(awk -F= '$1 == "pid" {print $2}' "$home/state/.docs-reader")
  [ "$pid" = "$pid2" ] || fail "a second ensure started another server"
  [ "$(reader "$home" status)" = "DOCS_READER: $base" ] || fail "status did not report the verified URL"
  pass "ensure is idempotent and status reports the live reader"

  kill "$pid"
  wait_until 10 sh -c "! kill -0 $pid 2>/dev/null" || fail "could not stop the reader for the restart case"
  if line=$(reader "$home" status); then
    fail "status claimed a dead reader was running: $line"
  fi
  assert_contains "$line" "not running" "status did not say the reader is down: $line"
  [ "$(ensure_url "$home")" = "$base" ] || fail "restart did not keep the home's port"
  pid2=$(awk -F= '$1 == "pid" {print $2}' "$home/state/.docs-reader")
  [ "$pid2" != "$pid" ] || fail "restart reused the dead pid"
  kill -0 "$pid2" 2>/dev/null || fail "restart did not start a fresh reader"
  pass "ensure restarts a dead reader on the same URL"

  # A record pointing at a live process that is not our reader must be
  # forgotten, never signaled.
  sleep 300 &
  sleeper=$!
  reader "$home" stop >/dev/null || fail "stop failed"
  printf 'pid=%s\nport=1\nurl=http://127.0.0.1:1/\nhome=%s\nconfig=%s\npython=%s\nstarted=0\n' \
    "$sleeper" "$(cd -P "$home" && pwd -P)" "$home/state/docs-reader/mkdocs.yml" "$FM_DOCS_READER_PYTHON" \
    > "$home/state/.docs-reader"
  line=$(reader "$home" stop)
  kill -0 "$sleeper" 2>/dev/null || fail "stop killed an unidentified process: $line"
  assert_contains "$line" "process untouched" "stop did not report leaving the unidentified process alone: $line"
  printf 'pid=%s\nport=1\nurl=http://127.0.0.1:1/\nhome=%s\nconfig=%s\npython=%s\nstarted=0\n' \
    "$sleeper" "$(cd -P "$home" && pwd -P)" "$home/state/docs-reader/mkdocs.yml" "$FM_DOCS_READER_PYTHON" \
    > "$home/state/.docs-reader"
  base=$(ensure_url "$home")
  kill -0 "$sleeper" 2>/dev/null || fail "ensure killed an unidentified process"
  kill "$sleeper" 2>/dev/null || true
  pid2=$(awk -F= '$1 == "pid" {print $2}' "$home/state/.docs-reader")
  [ "$pid2" != "$sleeper" ] || fail "ensure kept the unidentified pid as its reader"
  pass "stop and ensure leave an unidentified pid untouched and recover"
}

test_no_writes_into_data_and_source_unchanged() {
  local home base before after
  home=$(new_home pristine)
  before=$(cd "$home/data" && find . -not -type d | LC_ALL=C sort | xargs -I{} sh -c 'printf "%s " "{}"; if [ -L "{}" ]; then readlink "{}"; else cksum < "{}"; fi')
  base=$(ensure_url "$home")
  http_body "$base/nested/report/" >/dev/null
  http_body "$base/" >/dev/null
  after=$(cd "$home/data" && find . -not -type d | LC_ALL=C sort | xargs -I{} sh -c 'printf "%s " "{}"; if [ -L "{}" ]; then readlink "{}"; else cksum < "{}"; fi')
  [ "$before" = "$after" ] || fail "serving changed the data tree:
before: $before
after: $after"
  assert_present "$home/state/docs-reader/mkdocs.yml" "the generated configuration is not under state/"
  pass "serving leaves data/ byte-identical and keeps generated files under state/"
}

test_disabled_paths_print_no_url() {
  local home line rc
  home=$(new_home disabled)
  printf 'off\n' > "$home/config/docs-reader"
  line=$(reader "$home" ensure); rc=$?
  [ "$rc" -ne 0 ] || fail "ensure succeeded while turned off"
  assert_contains "$line" "turned off by config/docs-reader" "the off switch was not reported: $line"
  assert_not_contains "$line" "http://" "a URL was printed while turned off"
  rm "$home/config/docs-reader"
  line=$(FM_DOCS_READER_TEST_ALLOW=0 FM_HOME="$home" "$READER" ensure); rc=$?
  [ "$rc" -ne 0 ] || fail "ensure started a server under the test harness without the allow flag"
  assert_contains "$line" "not started under the test harness" "the harness guard was not reported: $line"
  assert_absent "$home/state/.docs-reader" "a record was written while disabled"
  line=$(FM_DOCS_READER_PYTHON=/nonexistent PATH=/usr/bin:/bin FM_HOME="$home" "$READER" ensure); rc=$?
  if [ "$rc" -eq 0 ]; then
    # python3 on the minimal PATH already carries the runtime; that is a legal
    # environment, so only the shape of a success line is checked here.
    assert_contains "$line" "DOCS_READER: http://127.0.0.1:" "an unverified URL shape: $line"
  else
    assert_contains "$line" "reader runtime not installed" "a missing runtime was not explained: $line"
    assert_not_contains "$line" "http://" "a URL was printed without a runtime"
  fi
  pass "off switch, harness guard, and missing runtime print a reason and never a URL"
}

test_install_from_pinned_requirements() {
  local home out
  if [ "${FM_DOCS_READER_INSTALL_TEST:-0}" != 1 ]; then
    printf 'skip: set FM_DOCS_READER_INSTALL_TEST=1 to exercise the network-dependent pinned install\n'
    return 0
  fi
  home=$(new_home install)
  out=$(FM_DOCS_READER_PYTHON='' FM_HOME="$home" "$READER" install 2>&1) || fail "install failed: $out"
  assert_contains "$out" "DOCS_READER_INSTALL: ok" "install did not report success: $out"
  assert_present "$home/state/docs-reader/venv/bin/python" "install created no venv"
  out=$(FM_DOCS_READER_PYTHON='' FM_HOME="$home" "$READER" install 2>&1) || fail "second install failed: $out"
  assert_contains "$out" "already installed" "install was not idempotent: $out"
  out=$(FM_DOCS_READER_PYTHON='' FM_HOME="$home" "$READER" ensure) || fail "ensure with the installed venv failed: $out"
  assert_contains "$out" "DOCS_READER: http://127.0.0.1:" "the installed runtime did not serve: $out"
  pass "install creates the pinned runtime idempotently and the reader serves from it"
}

# add_volume <home> <sections>: one task-like section directory per index, the
# shape the real data/ tree has (one directory per task, each with a brief and
# sometimes a report or nested evidence), so navigation is tested at the
# volume that broke it rather than with a handful of pages.
add_volume() {
  local home=$1 sections=$2 i dir
  i=1
  while [ "$i" -le "$sections" ]; do
    dir="$home/data/section-$(printf '%03d' "$i")"
    mkdir -p "$dir"
    printf '# Section %s brief\n\nBody %s.\n\n## Second section\n\nMore.\n' "$i" "$i" > "$dir/brief.md"
    if [ $((i % 10)) -eq 0 ]; then
      mkdir -p "$dir/evidence/deeper"
      printf '# Section %s report\n\nSee [notes](evidence/notes.md#detail).\n' "$i" > "$dir/report.md"
      printf '# Notes\n\n## Detail\n\nEvidence.\n' > "$dir/evidence/notes.md"
      printf '# Deeper\n\nDeep.\n' > "$dir/evidence/deeper/deep.md"
    fi
    i=$((i + 1))
  done
  mkdir -p "$home/data/a-representative-deliberately-long-task-directory-name-for-wrapping"
  printf '# A representative deliberately long heading that keeps going to exercise wrapping in the navigation\n\nText.\n' \
    > "$home/data/a-representative-deliberately-long-task-directory-name-for-wrapping/report.md"
}

# nav_shape <python> <html-file> <expect...>: structural assertions over one
# served page, expressed against the page a browser receives rather than the
# template that produced it. Prints nothing on success, one reason per failure.
nav_shape() {
  local python=$1 file=$2
  shift 2
  "$python" - "$file" "$@" <<'PY'
import sys
from html.parser import HTMLParser

class Page(HTMLParser):
    def __init__(self):
        super().__init__()
        self.stack = []          # (tag, attrs, record) for open elements
        self.tree_links = []     # (href, aria_current, open_ancestors, depth)
        self.navbar_links = []   # hrefs inside the theme's top navbar list
        self.dropdown_links = [] # hrefs rendered as theme dropdown items
        self.sections = []       # {'open': bool, 'on_path': bool} per tree <details>
        self.trees = 0
        self.toggle = None
        self.panel = None
    def _inside(self, pred):
        return any(pred(t, a) for t, a, _ in self.stack)
    def _in_tree(self):
        return self._inside(lambda t, a: t == 'nav' and a.get('aria-label') == 'Documents')
    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        record = None
        if tag == 'nav' and a.get('aria-label') == 'Documents':
            self.trees += 1
        if tag == 'details' and self._in_tree():
            record = {'open': 'open' in a, 'on_path': False}
            self.sections.append(record)
        if tag == 'a' and 'href' in a:
            if self._in_tree():
                ancestors = [r for t, _, r in self.stack if t == 'details' and r is not None]
                self.tree_links.append((a['href'], a.get('aria-current'), sum(r['open'] for r in ancestors), len(ancestors)))
                if a.get('aria-current') == 'page':
                    for r in ancestors:
                        r['on_path'] = True
            # previous/next page links legitimately live in the top bar
            if a.get('rel') not in ('prev', 'next') and self._inside(lambda t, x: t == 'ul' and 'navbar-nav' in (x.get('class') or '').split()):
                self.navbar_links.append(a['href'])
            if 'dropdown-item' in (a.get('class') or '').split():
                self.dropdown_links.append(a['href'])
        if tag == 'button' and a.get('data-bs-toggle') == 'offcanvas' and a.get('data-bs-target') == '#fm-docs-nav':
            self.toggle = a
        if a.get('id') == 'fm-docs-nav':
            self.panel = a
        if tag not in ('br', 'img', 'input', 'link', 'meta', 'hr'):
            self.stack.append((tag, a, record))
    def handle_endtag(self, tag):
        for i in range(len(self.stack) - 1, -1, -1):
            if self.stack[i][0] == tag:
                del self.stack[i:]
                break

page = Page()
page.feed(open(sys.argv[1], encoding='utf-8').read())
problems = []
expect = dict(arg.split('=', 1) for arg in sys.argv[2:])
if page.trees != 1:
    problems.append(f'expected one navigation tree labelled Documents, found {page.trees}')
if 'pages' in expect and len(page.tree_links) != int(expect['pages']):
    problems.append(f'tree lists {len(page.tree_links)} pages, expected {expect["pages"]}')
if 'sections_min' in expect and len(page.sections) < int(expect['sections_min']):
    problems.append(f'tree has {len(page.sections)} collapsible sections, expected at least {expect["sections_min"]}')
section_links = [h for h in page.navbar_links if 'section-' in h]
if section_links:
    problems.append(f'{len(section_links)} section pages are still rendered in the top navbar')
if any('section-' in h or 'nested' in h for h in page.dropdown_links):
    problems.append('section pages are still rendered as navbar dropdown items')
current = [t for t in page.tree_links if t[1] == 'page']
if 'current' in expect:
    if len(current) != 1:
        problems.append(f'expected exactly one aria-current page link, found {len(current)}')
    else:
        href, _, opened, depth = current[0]
        if href != expect['current']:
            problems.append(f'aria-current link href is {href!r}, expected {expect["current"]!r}')
        if opened != depth:
            problems.append(f'the current page sits under {depth} sections but only {opened} are expanded')
if 'closed_others' in expect:
    stray = [r for r in page.sections if r['open'] and not r['on_path']]
    if len(stray) > int(expect['closed_others']):
        problems.append(f'{len(stray)} sections outside the current branch are expanded')
if page.toggle is None:
    problems.append('no offcanvas toggle button targets #fm-docs-nav')
else:
    for attr in ('aria-controls', 'aria-expanded', 'aria-label'):
        if not page.toggle.get(attr):
            problems.append(f'the navigation toggle lacks {attr}')
if page.panel is None:
    problems.append('no #fm-docs-nav panel')
elif not page.panel.get('aria-labelledby'):
    problems.append('the navigation panel lacks aria-labelledby')
for p in problems:
    print(p)
sys.exit(1 if problems else 0)
PY
}

test_navigation_scales_with_inventory() {
  local home base out fixture_pages volume_pages
  home=$(new_home volume)
  add_volume "$home" 150
  base=$(ensure_url "$home")
  # fixture: index, nested/report, nested/deeper/deep; volume: 150 briefs,
  # 15 reports, 15 notes, 15 deep pages, one long-named report.
  fixture_pages=3
  volume_pages=$((150 + 15 + 15 + 15 + 1))
  http_body "$base/" > "$TMP_ROOT/volume-home.html"
  out=$(nav_shape "$FM_DOCS_READER_PYTHON" "$TMP_ROOT/volume-home.html" \
    "pages=$((fixture_pages + volume_pages))" sections_min=151) \
    || fail "home page navigation does not scale with a 150-section inventory:
$out"
  http_body "$base/section-077/brief/" > "$TMP_ROOT/volume-page.html"
  out=$(nav_shape "$FM_DOCS_READER_PYTHON" "$TMP_ROOT/volume-page.html" \
    "pages=$((fixture_pages + volume_pages))" sections_min=151 current=./ closed_others=0) \
    || fail "a deep page does not mark itself current inside one expanded section:
$out"
  http_body "$base/section-080/evidence/deeper/deep/" > "$TMP_ROOT/volume-deep.html"
  out=$(nav_shape "$FM_DOCS_READER_PYTHON" "$TMP_ROOT/volume-deep.html" \
    "pages=$((fixture_pages + volume_pages))" current=./ closed_others=0) \
    || fail "a third-level page does not expand its whole branch:
$out"
  body_has "$base/section-080/report/" 'href="../evidence/notes/#detail"' \
    || fail "a relative link with an anchor inside a volume section was not rewritten"
  pass "navigation renders a 150-section inventory as one collapsible tree, current branch expanded, others closed"
}

# The theme override is tracked in defaults/docs-reader-theme and copied into
# the home at ensure time. After a Firstmate update the running reader must
# pick the new override up on the next ensure without a restart, so the case
# runs the reader from a private copy of the tracked root, changes that copy,
# and watches the live server serve the change on the same pid.
test_ensure_converges_theme_on_live_reader() {
  local home base pid root marker digest_before digest_after
  home=$(new_home converge)
  root="$TMP_ROOT/root-converge"
  mkdir -p "$root/defaults"
  cp -R "$ROOT/defaults/docs-reader-theme" "$root/defaults/docs-reader-theme"
  base=$(FM_ROOT_OVERRIDE="$root" ensure_url "$home")
  pid=$(awk -F= '$1 == "pid" {print $2}' "$home/state/.docs-reader")
  body_has "$base/" 'aria-label="Documents"' || fail "the tracked override is not what the reader serves"
  digest_before=$(awk '$1 == "fm_theme_digest:" {print $2}' "$home/state/docs-reader/mkdocs.yml")
  [ -n "$digest_before" ] || fail "the generated configuration carries no theme digest"
  marker='.fm-converge-marker-4d2e { display: none; }'
  printf '\n%s\n' "$marker" >> "$root/defaults/docs-reader-theme/css/reader.css"
  [ "$(FM_ROOT_OVERRIDE="$root" ensure_url "$home")" = "$base" ] || fail "ensure changed the URL while converging"
  [ "$(awk -F= '$1 == "pid" {print $2}' "$home/state/.docs-reader")" = "$pid" ] \
    || fail "ensure restarted the reader instead of converging it in place"
  digest_after=$(awk '$1 == "fm_theme_digest:" {print $2}' "$home/state/docs-reader/mkdocs.yml")
  [ "$digest_after" != "$digest_before" ] || fail "the theme digest did not move after the override changed"
  wait_until 30 body_has "$base/css/reader.css" "$marker" \
    || fail "the running reader did not serve the changed override within 30s"
  kill -0 "$pid" 2>/dev/null || fail "the reader died while converging"
  [ "$(FM_ROOT_OVERRIDE="$root" ensure_url "$home")" = "$base" ] || fail "a third ensure failed"
  [ "$(awk '$1 == "fm_theme_digest:" {print $2}' "$home/state/docs-reader/mkdocs.yml")" = "$digest_after" ] \
    || fail "an unchanged override moved the digest again"
  pass "ensure converges a changed theme override into the running reader without a restart"
}

test_url_helper_path_safety
test_active_content_is_inert
test_serves_only_markdown_and_images
test_live_updates_without_restart
test_loopback_only_and_isolation
test_ensure_is_idempotent_and_restart_safe
test_no_writes_into_data_and_source_unchanged
test_disabled_paths_print_no_url
test_navigation_scales_with_inventory
test_ensure_converges_theme_on_live_reader
test_install_from_pinned_requirements
