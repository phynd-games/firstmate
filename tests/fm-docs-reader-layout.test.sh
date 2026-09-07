#!/usr/bin/env bash
# Browser-level layout tests for the local Markdown document reader
# (bin/fm-docs-reader.sh with defaults/docs-reader-theme/).
#
# tests/fm-docs-reader.test.sh proves what the server sends; this file proves
# what a reader sees once the page lays out, because the navigation failure it
# guards was invisible to HTTP assertions: with one section per task directory
# the theme's horizontal navbar grew taller than the viewport, and the sticky
# header covered every document at 100% zoom while the collapsed menu filled
# the whole viewport at 200%. Every case drives a real headless Chrome through
# chrome-devtools-axi against a 150-section home at three viewports: a desktop
# window at device scale 1, the same window at device scale 2 (what 200%
# browser zoom produces), and a phone-width window.
#
# Assertions are geometry and interaction, never a screenshot: the header stays
# one row, the document is hit-testable under it, the navigation panel scrolls
# on its own, a deep page opens from it, the panel closes on Escape and hands
# focus back, keyboard focus stays visible, the console stays clean, and no
# request leaves 127.0.0.1.
#
# Self-skipping: without chrome-devtools-axi on PATH, or without a reader
# runtime, it prints a gate skip. FM_DOCS_READER_BROWSER_TEST=0 forces the skip.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

READER="$ROOT/bin/fm-docs-reader.sh"
TMP_ROOT=$(fm_test_tmproot fm-docs-reader-layout)
export CHROME_DEVTOOLS_AXI_SESSION="fm-docs-layout-$$"

cleanup() {
  chrome-devtools-axi stop >/dev/null 2>&1 || true
  if [ -f "$TMP_ROOT/home/state/.docs-reader" ]; then
    FM_HOME="$TMP_ROOT/home" FM_DOCS_READER_TEST_ALLOW=1 "$READER" stop >/dev/null 2>&1 || true
  fi
  fm_test_cleanup
}
trap cleanup EXIT INT TERM

if [ "${FM_DOCS_READER_BROWSER_TEST:-1}" = 0 ]; then
  printf 'skip: FM_DOCS_READER_BROWSER_TEST=0\n'
  exit 0
fi
if ! command -v chrome-devtools-axi >/dev/null 2>&1; then
  printf 'skip: chrome-devtools-axi not on PATH (browser layout cases need it)\n'
  exit 0
fi
export FM_DOCS_READER_TEST_ALLOW=1
export FM_DOCS_READER_READY_SECS=30
if ! RUNTIME_PYTHON=$(FM_HOME="$TMP_ROOT/probe" "$READER" python 2>/dev/null); then
  printf 'skip: docs reader runtime (mkdocs, nh3, pygments) not found\n'
  exit 0
fi
export FM_DOCS_READER_PYTHON="$RUNTIME_PYTHON"

# --- fixture: the real shape of data/, one section per task ------------------
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/data"
printf '# Fixture home\n\nA home page.\n' > "$HOME_DIR/data/index.md"
i=1
while [ "$i" -le 150 ]; do
  dir="$HOME_DIR/data/section-$(printf '%03d' "$i")"
  mkdir -p "$dir"
  printf '# Section %s brief\n\nBody %s.\n\n## Second section\n\nMore.\n' "$i" "$i" > "$dir/brief.md"
  if [ $((i % 10)) -eq 0 ]; then
    mkdir -p "$dir/evidence"
    printf '# Section %s report\n\n| A | B |\n| --- | --- |\n| 1 | 2 |\n\n```bash\necho hi\n```\n\n## Findings\n\nText.\n\n### Detail\n\nMore.\n' "$i" > "$dir/report.md"
    printf '# Notes\n\n## Detail\n\nEvidence.\n' > "$dir/evidence/notes.md"
  fi
  i=$((i + 1))
done
mkdir -p "$HOME_DIR/data/a-representative-deliberately-long-task-directory-name-for-wrapping"
printf '# A representative deliberately long heading that keeps going to exercise wrapping\n\nText.\n' \
  > "$HOME_DIR/data/a-representative-deliberately-long-task-directory-name-for-wrapping/report.md"

line=$(FM_HOME="$HOME_DIR" "$READER" ensure) || fail "ensure failed: $line"
case "$line" in
  "DOCS_READER: http://127.0.0.1:"*) BASE=${line#DOCS_READER: } ;;
  *) fail "ensure printed no verified URL: $line" ;;
esac
BASE=${BASE%/}
# Emulation needs a selected page, so the session starts on the home page.
chrome-devtools-axi open "$BASE/" >/dev/null 2>&1 || fail "could not open the reader in the browser session"

# --- browser helpers ----------------------------------------------------------
# axi <args...>: chrome-devtools-axi prints errors as `error:` lines and exits
# 0, so the helper turns those into a failing status.
axi() {
  local out
  out=$(chrome-devtools-axi "$@" 2>&1)
  printf '%s\n' "$out"
  case "$out" in
    error:*|*$'\n'error:*) return 1 ;;
  esac
  return 0
}

# ev <js>: evaluate an expression that returns a plain string (no quotes or
# backslashes) and print it. The expression may be an IIFE.
ev() {
  local out
  out=$(axi eval "$1") || true
  printf '%s\n' "$out" | sed -n 's/^result: "\\"\(.*\)\\""$/\1/p'
}

# field <output> <key>: value of key=value inside a space-separated result.
field() {
  printf '%s\n' "$1" | tr ' ' '\n' | sed -n "s/^$2=//p" | head -n1
}

viewport() {  # <WxHxScale>
  axi emulate --viewport "$1" >/dev/null || fail "could not emulate viewport $1"
}

open_page() {  # <path>
  axi open "$BASE/$1" >/dev/null || fail "could not open $BASE/$1"
  axi wait 300 >/dev/null 2>&1 || true
}

# LAYOUT_JS reports the facts every viewport case checks: header height, where
# the document starts, whether the point at the document heading is actually
# hit-testable (an element inside the main region, not a header covering it),
# and the navigation panel's geometry.
LAYOUT_JS='(() => {
  const bar = document.querySelector(".navbar");
  const main = document.querySelector("[role=main]");
  const h1 = main.querySelector("h1");
  const r = h1.getBoundingClientRect();
  const hit = document.elementFromPoint(r.left + 4, r.top + 4);
  const nav = document.getElementById("fm-docs-nav");
  const body = nav && nav.querySelector(".offcanvas-body");
  const facts = ["vw=" + innerWidth, "vh=" + innerHeight, "barH=" + Math.round(bar.getBoundingClientRect().height),
    "h1Top=" + Math.round(r.top), "h1Hit=" + (hit && hit.closest("[role=main]") ? "main" : (hit ? hit.tagName : "none")),
    "docW=" + document.documentElement.scrollWidth];
  if (!nav || !body) return facts.concat(["navVisible=missing"]).join(" ");
  const cs = getComputedStyle(nav);
  const visible = cs.visibility !== "hidden" && cs.display !== "none" && nav.getBoundingClientRect().right > 0;
  return facts.concat(["navVisible=" + visible, "navScrolls=" + (body.scrollHeight > body.clientHeight + 4),
    "navOverflow=" + getComputedStyle(body).overflowY, "navBottom=" + Math.round(nav.getBoundingClientRect().bottom)]).join(" ");
})()'

assert_header_and_document() {  # <facts> <label>
  local facts=$1 label=$2 barH vh h1Top h1Hit docW vw
  barH=$(field "$facts" barH); vh=$(field "$facts" vh); h1Top=$(field "$facts" h1Top)
  h1Hit=$(field "$facts" h1Hit); docW=$(field "$facts" docW); vw=$(field "$facts" vw)
  [ -n "$barH" ] || fail "$label: no layout facts came back: $facts"
  [ "$barH" -lt $((vh / 4)) ] || fail "$label: the header is $barH px tall in a $vh px viewport (it must stay a slim bar): $facts"
  [ "$h1Top" -ge 0 ] && [ "$h1Top" -lt "$vh" ] || fail "$label: the document heading starts at $h1Top px, outside the $vh px viewport: $facts"
  [ "$h1Hit" = main ] || fail "$label: the point on the document heading hits $h1Hit, not the document (something covers it): $facts"
  [ "$docW" -le "$vw" ] || fail "$label: the page scrolls horizontally ($docW px wide in a $vw px viewport): $facts"
}

# --- desktop, device scale 1 --------------------------------------------------
test_desktop_layout() {
  local facts
  viewport "1920x1080x1"
  open_page ""
  facts=$(ev "$LAYOUT_JS")
  assert_header_and_document "$facts" "desktop 100%"
  [ "$(field "$facts" navVisible)" = true ] || fail "desktop: the navigation panel is not shown inline: $facts"
  [ "$(field "$facts" navScrolls)" = true ] || fail "desktop: the 150-section navigation does not scroll on its own: $facts"
  [ "$(field "$facts" navOverflow)" = auto ] || fail "desktop: the navigation body is not its own scroll container: $facts"
  [ "$(field "$facts" navBottom)" -le 1080 ] || fail "desktop: the navigation panel extends below the viewport: $facts"
  # Scrolling the document must not let the header cover it.
  facts=$(ev '(() => { window.scrollTo(0, 400); const main = document.querySelector("[role=main]"); const r = main.getBoundingClientRect(); const bar = document.querySelector(".navbar").getBoundingClientRect(); return ["scrollY=" + Math.round(scrollY), "barBottom=" + Math.round(bar.bottom), "mainTop=" + Math.round(r.top)].join(" "); })()')
  [ "$(field "$facts" barBottom)" -lt 120 ] || fail "desktop: after scrolling, the header still occupies $(field "$facts" barBottom) px: $facts"
  pass "desktop 100%: slim header, document hit-testable, navigation scrolls independently"
}

test_desktop_deep_link_and_keyboard() {
  local facts before after
  viewport "1920x1080x1"
  open_page ""
  # Open a section deep in the list by its disclosure, then follow a page link.
  facts=$(ev '(() => { const nav = document.getElementById("fm-docs-nav"); const sums = [...nav.querySelectorAll("summary")]; const s = sums.find(x => x.textContent.trim() === "Section 120"); if (!s) return "summary=missing"; const d = s.parentElement; s.focus(); const focusRing = getComputedStyle(s).outlineStyle; s.click(); const link = d.querySelector("a[href*=\"section-120/report\"]"); const lr = link.getBoundingClientRect(); const body = nav.querySelector(".offcanvas-body"); const br = body.getBoundingClientRect(); return ["summary=found", "open=" + d.hasAttribute("open"), "linkInPanel=" + (lr.top >= br.top - 1 && lr.bottom <= br.bottom + 1), "focusOutline=" + focusRing, "activeIsSummary=" + (document.activeElement === s)].join(" "); })()')
  [ "$(field "$facts" summary)" = found ] || fail "desktop: section 120 has no disclosure in the tree: $facts"
  [ "$(field "$facts" open)" = true ] || fail "desktop: clicking the disclosure did not expand the section: $facts"
  [ "$(field "$facts" activeIsSummary)" = true ] || fail "desktop: the disclosure did not take keyboard focus: $facts"
  [ "$(field "$facts" focusOutline)" != none ] || fail "desktop: a focused disclosure shows no focus outline: $facts"
  before=$(ev 'location.pathname')
  axi eval '(() => { const link = document.querySelector("#fm-docs-nav a[href*=\"section-120/report\"]"); link.scrollIntoView({block: "center"}); link.click(); return "clicked"; })()' >/dev/null
  axi wait 1200 >/dev/null 2>&1 || true
  after=$(ev 'location.pathname')
  [ "$after" = "/section-120/report/" ] || fail "desktop: following a deep link went from $before to $after"
  facts=$(ev "$LAYOUT_JS")
  assert_header_and_document "$facts" "desktop deep page"
  facts=$(ev '(() => { const nav = document.getElementById("fm-docs-nav"); const cur = nav.querySelector("a[aria-current=page]"); const d = cur && cur.closest("details"); const body = nav.querySelector(".offcanvas-body"); const cr = cur.getBoundingClientRect(); const br = body.getBoundingClientRect(); const opened = [...nav.querySelectorAll("details[open]")].length; return ["current=" + (cur ? cur.getAttribute("href") : "none"), "branchOpen=" + (d && d.hasAttribute("open")), "openCount=" + opened, "currentInView=" + (cr.top >= br.top - 1 && cr.bottom <= br.bottom + 1), "toc=" + document.querySelectorAll(".fm-toc .nav-link").length].join(" "); })()')
  [ "$(field "$facts" current)" = "./" ] || fail "desktop deep page: no current page link in the tree: $facts"
  [ "$(field "$facts" branchOpen)" = true ] || fail "desktop deep page: the current section is collapsed: $facts"
  [ "$(field "$facts" openCount)" = 1 ] || fail "desktop deep page: $(field "$facts" openCount) sections are expanded, expected only the current one: $facts"
  [ "$(field "$facts" currentInView)" = true ] || fail "desktop deep page: the navigation did not scroll the current page into view: $facts"
  [ "$(field "$facts" toc)" -ge 2 ] || fail "desktop deep page: the on-this-page outline lists $(field "$facts" toc) headings: $facts"
  # Keyboard: Enter on a focused disclosure toggles it.
  facts=$(ev '(() => { const s = [...document.querySelectorAll("#fm-docs-nav summary")].find(x => x.textContent.trim() === "Section 010"); s.focus(); return "focused=" + (document.activeElement === s); })()')
  [ "$(field "$facts" focused)" = true ] || fail "desktop: could not focus a disclosure by script: $facts"
  axi press Enter >/dev/null
  facts=$(ev '(() => { const s = [...document.querySelectorAll("#fm-docs-nav summary")].find(x => x.textContent.trim() === "Section 010"); return "open=" + s.parentElement.hasAttribute("open"); })()')
  [ "$(field "$facts" open)" = true ] || fail "desktop: Enter on a focused disclosure did not expand it: $facts"
  pass "desktop: deep section opens, its page loads with the branch expanded and scrolled into view, keyboard toggles work"
}

# --- the same window at device scale 2 (200% browser zoom) --------------------
test_zoomed_menu_scrolls_closes_and_navigates() {
  local facts label=$1 spec=$2
  viewport "$spec"
  open_page ""
  facts=$(ev "$LAYOUT_JS")
  assert_header_and_document "$facts" "$label closed"
  [ "$(field "$facts" navVisible)" = false ] || fail "$label: the navigation panel is open before anyone asked: $facts"
  facts=$(ev '(() => { const b = document.querySelector("[data-bs-toggle=offcanvas][data-bs-target=\"#fm-docs-nav\"]"); const r = b.getBoundingClientRect(); return ["toggleVisible=" + (r.width > 0 && r.height > 0 && r.bottom <= innerHeight), "expanded=" + b.getAttribute("aria-expanded"), "label=" + (b.getAttribute("aria-label") || "").split(" ").join("_")].join(" "); })()')
  [ "$(field "$facts" toggleVisible)" = true ] || fail "$label: the Documents toggle is not visible: $facts"
  [ "$(field "$facts" expanded)" = false ] || fail "$label: the toggle does not announce its collapsed state: $facts"
  axi eval 'document.querySelector("[data-bs-toggle=offcanvas][data-bs-target=\"#fm-docs-nav\"]").click()' >/dev/null
  axi wait 700 >/dev/null 2>&1 || true
  facts=$(ev '(() => { const nav = document.getElementById("fm-docs-nav"); const body = nav.querySelector(".offcanvas-body"); const b = document.querySelector("[data-bs-toggle=offcanvas][data-bs-target=\"#fm-docs-nav\"]"); const r = nav.getBoundingClientRect(); const sums = [...nav.querySelectorAll("summary")]; const deep = sums.find(x => x.textContent.trim() === "Section 140"); body.scrollTop = body.scrollHeight; const dr = deep.getBoundingClientRect(); const br = body.getBoundingClientRect(); return ["shown=" + nav.classList.contains("show"), "expanded=" + b.getAttribute("aria-expanded"), "panelW=" + Math.round(r.width), "panelFits=" + (r.width <= innerWidth && r.height <= innerHeight + 1), "scrolls=" + (body.scrollHeight > body.clientHeight + 4), "scrolledTo=" + Math.round(body.scrollTop), "deepReachable=" + (dr.top >= br.top - 1 && dr.bottom <= br.bottom + 1), "focusInside=" + nav.contains(document.activeElement), "role=" + nav.getAttribute("role"), "modal=" + nav.getAttribute("aria-modal")].join(" "); })()')
  [ "$(field "$facts" shown)" = true ] || fail "$label: the navigation panel did not open: $facts"
  [ "$(field "$facts" expanded)" = true ] || fail "$label: the toggle does not announce the open panel: $facts"
  [ "$(field "$facts" panelFits)" = true ] || fail "$label: the open panel is larger than the viewport: $facts"
  [ "$(field "$facts" scrolls)" = true ] || fail "$label: the open panel does not scroll on its own: $facts"
  [ "$(field "$facts" scrolledTo)" -gt 0 ] || fail "$label: the panel body did not scroll: $facts"
  [ "$(field "$facts" deepReachable)" = true ] || fail "$label: a section near the end of the list cannot be scrolled into view: $facts"
  [ "$(field "$facts" role)" = dialog ] || fail "$label: the open panel is not announced as a dialog: $facts"
  # Escape closes it and hands focus back to the toggle.
  axi press Escape >/dev/null
  axi wait 700 >/dev/null 2>&1 || true
  facts=$(ev '(() => { const nav = document.getElementById("fm-docs-nav"); const b = document.querySelector("[data-bs-toggle=offcanvas][data-bs-target=\"#fm-docs-nav\"]"); return ["shown=" + nav.classList.contains("show"), "expanded=" + b.getAttribute("aria-expanded"), "focusOnToggle=" + (document.activeElement === b)].join(" "); })()')
  [ "$(field "$facts" shown)" = false ] || fail "$label: Escape did not close the navigation panel: $facts"
  [ "$(field "$facts" expanded)" = false ] || fail "$label: after Escape the toggle still announces an open panel: $facts"
  [ "$(field "$facts" focusOnToggle)" = true ] || fail "$label: focus did not return to the toggle after Escape: $facts"
  facts=$(ev "$LAYOUT_JS")
  assert_header_and_document "$facts" "$label after Escape"
  # Open again, expand a deep section, follow its page link.
  axi eval 'document.querySelector("[data-bs-toggle=offcanvas][data-bs-target=\"#fm-docs-nav\"]").click()' >/dev/null
  axi wait 700 >/dev/null 2>&1 || true
  # The notes page sits two disclosures deep (section, then its evidence
  # folder); a reader opens each one on the way down.
  facts=$(ev '(() => { const nav = document.getElementById("fm-docs-nav"); const link = nav.querySelector("a[href*=\"section-140/evidence/notes\"]"); const chain = []; for (let d = link.closest("details"); d; d = d.parentElement.closest("details")) chain.unshift(d); let opened = 0; chain.forEach(d => { const s = d.querySelector(":scope > summary"); s.scrollIntoView({block: "center"}); if (!d.open) s.click(); if (d.open) opened++; }); link.scrollIntoView({block: "center"}); const lr = link.getBoundingClientRect(); const hit = document.elementFromPoint(lr.left + 4, lr.top + 4); const ok = hit && (hit === link || link.contains(hit)); if (ok) link.click(); return ["disclosures=" + chain.length, "opened=" + opened, "clickable=" + ok].join(" "); })()')
  [ "$(field "$facts" opened)" = "$(field "$facts" disclosures)" ] || fail "$label: not every disclosure above the deep page opened: $facts"
  [ "$(field "$facts" clickable)" = true ] || fail "$label: the deep page link is not hit-testable inside the open panel: $facts"
  axi wait 1200 >/dev/null 2>&1 || true
  facts=$(ev 'location.pathname')
  [ "$facts" = "/section-140/evidence/notes/" ] || fail "$label: following the deep link landed on $facts"
  facts=$(ev "$LAYOUT_JS")
  assert_header_and_document "$facts" "$label deep page"
  [ "$(field "$facts" navVisible)" = false ] || fail "$label: the panel stayed open over the new page: $facts"
  pass "$label: panel opens within the viewport, scrolls to the end, closes on Escape with focus returned, deep link navigates"
}

test_clean_console_and_local_network() {
  local console network
  viewport "1920x1080x1"
  open_page "section-120/report/"
  axi eval 'document.querySelector("#theme-menu") && document.querySelector("[data-bs-theme-value=dark]").click()' >/dev/null
  axi wait 300 >/dev/null 2>&1 || true
  facts=$(ev '(() => { return ["theme=" + document.documentElement.getAttribute("data-bs-theme"), "darkCode=" + (document.getElementById("hljs-dark") ? !document.getElementById("hljs-dark").disabled : "absent")].join(" "); })()')
  [ "$(field "$facts" theme)" = dark ] || fail "the theme toggle does not switch to dark: $facts"
  [ "$(field "$facts" darkCode)" = true ] || fail "dark mode does not enable the dark code stylesheet: $facts"
  axi eval 'document.querySelector("[data-bs-theme-value=auto]").click()' >/dev/null
  console=$(axi console --type error)
  case "$console" in
    *"[error]"*) fail "the page logs console errors:
$console" ;;
  esac
  network=$(axi network)
  if printf '%s\n' "$network" | grep -E '^reqid=[0-9]+ ' | grep -v 'http://127\.0\.0\.1:' >/dev/null; then
    fail "a request left the loopback interface:
$(printf '%s\n' "$network" | grep -E '^reqid=' | grep -v 'http://127\.0\.0\.1:')"
  fi
  if printf '%s\n' "$network" | grep -E '^reqid=[0-9]+ .*\[(4|5)[0-9][0-9]\]' >/dev/null; then
    fail "a page asset failed to load:
$(printf '%s\n' "$network" | grep -E '\[(4|5)[0-9][0-9]\]')"
  fi
  pass "theme toggle works, console has no errors, every request stays on loopback and succeeds"
}

test_desktop_layout
test_desktop_deep_link_and_keyboard
test_zoomed_menu_scrolls_closes_and_navigates "zoomed 200%" "960x540x2"
test_zoomed_menu_scrolls_closes_and_navigates "phone width" "390x844x2"
test_clean_console_and_local_network
