// Render a built control-plane dashboard's shipped inline script under a
// minimal DOM shim and print what the renderer actually produced, so page
// behavior is asserted through the real template rather than by reading its
// source text.
//
// Usage: node dashboard-render-harness.mjs <built-page.html> [options]
//   --open-report <id>   click that report's opener and report the drawer
//   --filter <text>      type <text> into the report filter first
//   --press-escape       dispatch Escape on the document after opening
// Prints one JSON document describing the rendered page.
import { readFileSync } from "node:fs";

const argv = process.argv.slice(2);
const file = argv[0];
const optionOf = (name) => {
  const i = argv.indexOf(name);
  return i === -1 ? null : argv[i + 1];
};
const openReport = optionOf("--open-report");
const filterText = optionOf("--filter");
const pressEscape = argv.includes("--press-escape");

const html = readFileSync(file, "utf8");

class Node {
  constructor(tag) {
    this.tagName = String(tag).toUpperCase();
    this.className = "";
    this.children = [];
    this.attributes = {};
    this._text = "";
    this.hidden = false;
    this.value = "";
    this.parentNode = null;
    this.listeners = {};
    this.classList = {
      add: (c) => {
        if (!this.className.split(/\s+/).includes(c)) {
          this.className = (this.className + " " + c).trim();
        }
      },
      remove: (c) => {
        this.className = this.className.split(/\s+/).filter((x) => x && x !== c).join(" ");
      },
      contains: (c) => this.className.split(/\s+/).includes(c),
    };
  }
  get textContent() {
    return this.children.length
      ? this.children.map((c) => c.textContent).join("")
      : this._text;
  }
  set textContent(v) { this._text = String(v); this.children = []; }
  appendChild(n) { n.parentNode = this; this.children.push(n); return n; }
  setAttribute(k, v) { this.attributes[k] = String(v); }
  getAttribute(k) { return Object.prototype.hasOwnProperty.call(this.attributes, k) ? this.attributes[k] : null; }
  addEventListener(type, fn) {
    (this.listeners[type] = this.listeners[type] || []).push(fn);
  }
  dispatch(type, event) {
    (this.listeners[type] || []).forEach((fn) => fn(event || { target: this }));
  }
}

class TextNode {
  constructor(text) { this._text = String(text); this.children = []; this.className = ""; this.tagName = "#text"; }
  get textContent() { return this._text; }
}

const byId = new Map();
const documentListeners = {};

const dataNode = new Node("script");
dataNode.textContent = html
  .split('<script id="fm-dashboard-data" type="application/json">')[1]
  .split("</script>")[0];
byId.set("fm-dashboard-data", dataNode);
// Ids the shipped markup declares. Anything else the page asks for is minted
// lazily, so the shim tracks whatever the template actually uses.
["cp-main", "cp-nav-meta", "cp-tabs", "cp-stats", "cp-notices", "cp-sections",
  "cp-provenance", "cp-drawer", "cp-drawer-title", "cp-drawer-path",
  "cp-drawer-body", "cp-drawer-close"].forEach((id) => byId.set(id, new Node("div")));

globalThis.document = {
  createElement: (tag) => new Node(tag),
  createTextNode: (t) => new TextNode(t),
  getElementById: (id) => {
    if (!byId.has(id)) byId.set(id, new Node("div"));
    return byId.get(id);
  },
  addEventListener: (type, fn) => { (documentListeners[type] = documentListeners[type] || []).push(fn); },
};
globalThis.window = {};

const script = html.slice(html.lastIndexOf("<script>") + "<script>".length, html.lastIndexOf("</script>"));
new Function(script)();

// --- extraction helpers ---------------------------------------------------
const hasClass = (n, c) => String(n.className || "").split(/\s+/).includes(c);
function walk(node, out = []) {
  (node.children || []).forEach((c) => { out.push(c); walk(c, out); });
  return out;
}
const all = (root, cls) => walk(root).filter((n) => hasClass(n, cls));
const first = (root, cls) => all(root, cls)[0] || null;
const textOf = (n) => (n ? n.textContent : "");
const tagCount = (root, tag) => walk(root).filter((n) => n.tagName === tag.toUpperCase()).length;

const badgesOf = (row) =>
  (row.children || [])
    .concat(...(row.children || []).map((c) => c.children || []))
    .filter((c) => hasClass(c, "fm-badge"))
    .map((c) => ({
      tone: String(c.className).replace(/.*fm-badge--/, "").trim(),
      text: c.textContent,
    }));

// The page holds most nodes it creates directly and never looks them up, so
// resolve an id by walking the rendered tree rather than by the shim's
// getElementById registry, which only knows the ids the page asked for.
function findById(id) {
  for (const root of byId.values()) {
    if (root.getAttribute && root.getAttribute("id") === id) return root;
    const hit = walk(root).find((n) => n.getAttribute && n.getAttribute("id") === id);
    if (hit) return hit;
  }
  return null;
}

const hrefsIn = (root) =>
  walk(root).filter((n) => n.tagName === "A").map((n) => n.getAttribute("href"));

function sectionNode(id) {
  return walk(byId.get("cp-sections")).find((n) => n.getAttribute && n.getAttribute("id") === "cp-sec-" + id) || new Node("div");
}
function tableOf(root) {
  return walk(root)
    .filter((n) => n.tagName === "TR")
    .map((tr) => (tr.children || []).map((cell) => cell.textContent));
}

// --- optional interactions ------------------------------------------------
if (filterText !== null && filterText !== undefined) {
  const input = findById("cp-report-filter");
  if (input) { input.value = filterText; input.dispatch("input", { target: input }); }
}
if (openReport) {
  const opener = walk(byId.get("cp-sections"))
    .find((n) => n.getAttribute && n.getAttribute("data-open-report") === openReport);
  if (opener) opener.dispatch("click", { target: opener });
}
if (pressEscape) {
  (documentListeners.keydown || []).forEach((fn) => fn({ key: "Escape" }));
}

// --- report ---------------------------------------------------------------
const main = byId.get("cp-main");
const errorNode = all(main, "cp-drawer__title")[0];
const failedClosed = errorNode && !byId.get("cp-sections").children.length
  ? errorNode.textContent + " " + textOf(all(main, "cp-state__d")[0])
  : "";

const stats = (byId.get("cp-stats").children || []).map((s) => ({
  n: Number(textOf(first(s, "cp-stat__num"))),
  label: textOf(first(s, "cp-stat__label")),
  alert: hasClass(s, "cp-stat--alert"),
}));

const tabs = (byId.get("cp-tabs").children || []).map((t) => ({
  label: t._text.trim(),
  count: Number(textOf(first(t, "cp-tab__n"))),
  active: hasClass(t, "is-active"),
}));

const notices = (byId.get("cp-notices").children || []).map((n) => ({
  tone: String(n.className).replace(/.*cp-notice--/, "").trim(),
  title: textOf(first(n, "cp-notice__title")),
  detail: textOf(first(n, "cp-notice__detail")),
}));

const workers = all(sectionNode("workers"), "cp-worker").map((card) => {
  const kvRoot = first(card, "cp-kv");
  const kv = [];
  if (kvRoot) {
    const cells = kvRoot.children || [];
    for (let i = 0; i + 1 < cells.length; i += 2) kv.push([cells[i].textContent, cells[i + 1].textContent]);
  }
  const folds = walk(card).filter((n) => n.tagName === "DETAILS");
  const eventFold = folds.find((f) => textOf(f.children[0]).indexOf("Event history") === 0);
  return {
    id: card.getAttribute("data-task"),
    title: textOf(first(card, "cp-worker__id")),
    sub: textOf(first(card, "cp-worker__repo")),
    badges: badgesOf(first(card, "cp-worker__top") || card),
    state: {
      value: textOf(first(card, "cp-state__v")),
      details: all(card, "cp-state__d").map(textOf),
    },
    kv,
    foldSummaries: folds.map((f) => textOf(f.children[0])),
    events: eventFold
      ? all(eventFold, "cp-event").map((e) => ({
        verb: badgesOf(e)[0] ? badgesOf(e)[0].text : "",
        tone: badgesOf(e)[0] ? badgesOf(e)[0].tone : "",
        note: textOf(first(e, "cp-event__note")),
      }))
      : [],
    eventNotes: eventFold ? all(eventFold, "cp-event__note--empty").map(textOf) : [],
    commands: all(card, "cp-copy").map(textOf),
  };
});

const rowsOf = (root) => all(root, "cp-row").map((r) => ({
  title: textOf(first(r, "cp-row__title")),
  sub: textOf(first(r, "cp-row__sub")),
  badges: badgesOf(first(r, "cp-row__side") || r),
  hidden: !!r.hidden,
  id: r.getAttribute("data-report") || null,
}));

const drawer = byId.get("cp-drawer");
const drawerBody = byId.get("cp-drawer-body");
const drawerReport = {
  open: hasClass(drawer, "is-open"),
  title: textOf(byId.get("cp-drawer-title")),
  path: textOf(byId.get("cp-drawer-path")),
  counts: {
    table: tagCount(drawerBody, "table"),
    pre: tagCount(drawerBody, "pre"),
    code: tagCount(drawerBody, "code"),
    script: tagCount(drawerBody, "script"),
    img: tagCount(drawerBody, "img"),
    iframe: tagCount(drawerBody, "iframe"),
    a: tagCount(drawerBody, "a"),
    heading: ["h1", "h2", "h3", "h4"].reduce((n, t) => n + tagCount(drawerBody, t), 0),
    li: tagCount(drawerBody, "li"),
    strong: tagCount(drawerBody, "strong"),
  },
  hrefs: walk(drawerBody).filter((n) => n.tagName === "A").map((n) => n.getAttribute("href")),
  text: drawerBody.textContent,
};

process.stdout.write(JSON.stringify({
  error: failedClosed,
  stats,
  tabs,
  notices,
  workers,
  calls: rowsOf(sectionNode("calls")),
  backlog: rowsOf(sectionNode("backlog")),
  delivery: tableOf(sectionNode("delivery")),
  deliveryHrefs: hrefsIn(sectionNode("delivery")),
  workerHrefs: hrefsIn(sectionNode("workers")),
  reports: rowsOf(sectionNode("reports")),
  reportsFooter: all(sectionNode("reports"), "cp-empty").map(textOf),
  wakes: tableOf(sectionNode("wakes")),
  usage: tableOf(sectionNode("usage")),
  usageTotals: all(sectionNode("usage"), "cp-row__title").map(textOf),
  sources: tableOf(sectionNode("sources")),
  provenance: textOf(byId.get("cp-provenance")),
  navMeta: (byId.get("cp-nav-meta").children || []).map((n) => n.textContent),
  drawer: drawerReport,
}) + "\n");
