// Quota rail burn glow and running-now list. Runs newtab.js against the same
// tiny DOM stub as machines_card_test.js (plus first/lastChild, which the rail
// uses) with one /cards payload. No network.
// Run: node tests/burn_card_test.js
"use strict";
const fs = require("fs"), path = require("path"), vm = require("vm"), assert = require("assert");
const SRC = process.env.NEWTAB_JS || path.join(__dirname, "..", "extension", "newtab.js");

class Node {
  constructor(tag, text) { this.tagName = tag; this.children = []; this.attrs = {}; this.className = ""; this.style = { setProperty() {} }; this._text = text; this.hidden = false; this.value = ""; this.placeholder = ""; }
  get textContent() { return this._text != null ? this._text : this.children.map((c) => c.textContent).join(" "); }
  set textContent(v) { this._text = String(v); this.children = []; }
  appendChild(c) { this.children.push(c); return c; }
  get lastChild() { return this.children[this.children.length - 1] || null; }
  get firstChild() { return this.children[0] || null; }
  replaceChildren(...kids) { this._text = null; this.children = kids.filter((k) => k != null); }
  append(...kids) { kids.forEach((k) => this.appendChild(typeof k === "object" ? k : new Node("#text", String(k)))); }
  prepend(...kids) { this.children.unshift(...kids.map((k) => (typeof k === "object" ? k : new Node("#text", String(k))))); }
  insertBefore(c) { this.children.unshift(c); return c; }
  setAttribute(k, v) { this.attrs[k] = String(v); }
  getAttribute(k) { return k in this.attrs ? this.attrs[k] : null; }
  removeAttribute(k) { delete this.attrs[k]; }
  addEventListener() {}
  get classList() { const n = this; return { add() {}, remove() {}, toggle() {}, contains: (c) => n.className.split(/\s+/).includes(c) }; }
  querySelector() { return null; }
  querySelectorAll() { return []; }
  remove() {} focus() {} select() {} blur() {}
  all() { return [this].concat(...this.children.map((c) => (c.all ? c.all() : []))); }
}

function run(payload) {
  const ids = {};
  const document = {
    visibilityState: "hidden", title: "",
    getElementById: (id) => (ids[id] = ids[id] || new Node("div")),
    createElement: (t) => new Node(t),
    createTextNode: (t) => new Node("#text", t),
    addEventListener() {}, querySelector: () => null, querySelectorAll: () => [],
    body: new Node("body"), documentElement: new Node("html")
  };
  const ctx = { document, location: { search: "" }, URLSearchParams, console, Date, Math, JSON, setTimeout, clearTimeout,
    setInterval: () => 0, clearInterval() {}, Promise, isNaN, Number, String, Array, Object,
    fetch: () => Promise.resolve({ ok: true, status: 200, json: () => Promise.resolve(payload) }),
    localStorage: { getItem: () => null, setItem() {}, removeItem() {} } };
  ctx.window = ctx;
  vm.runInNewContext(fs.readFileSync(SRC, "utf8"), ctx, { filename: SRC });
  return new Promise((r) => setTimeout(() => r(ids.rail), 20));
}

const now = new Date();
const iso = (ms) => new Date(now.getTime() + ms).toISOString();
const seat = (o) => Object.assign({ status: "live", percent: 40, text: "40%", pace: "under", vendor: "claude", subscription: "claude",
  resets_at: iso(3 * 86400e3), window_s: 604800, verified_at: now.toISOString(), note: null, burn: "none" }, o);
const quota = (seats, drivers) => ({ cards: { quota: { fetched_at: now.toISOString(), error: null, data: { seats, host_suggestion: null, drivers } } } });
const SEATS = [
  seat({ seat: "claude_weekly", label: "Claude", burn: "strong" }),
  seat({ seat: "codex", label: "Codex", vendor: "codex", subscription: "codex", burn: "soft" }),
  seat({ seat: "cursor_models", label: "Cursor Models", vendor: "cursor", subscription: "cursor", burn: "none" }),
  seat({ seat: "supergrok", label: "SuperGrok", vendor: "grok", subscription: "grok", status: "unknown", percent: null, text: "unknown", burn: "strong" })
];
const row = (rail, id) => rail.all().find((n) => n.attrs && n.attrs["data-seat"] === id);

const tests = {
  async live_rows_get_the_burn_class_and_others_do_not() {
    const rail = await run(quota(SEATS, []));
    assert.ok(/\bburn-strong\b/.test(row(rail, "claude_weekly").className), row(rail, "claude_weekly").className);
    assert.strictEqual(row(rail, "claude_weekly").attrs["data-burn"], "strong");
    assert.ok(/\bburn-soft\b/.test(row(rail, "codex").className));
    for (const id of ["cursor_models", "supergrok"]) {
      assert.ok(!/burn-/.test(row(rail, id).className), `${id} glows: ${row(rail, id).className}`);
      assert.ok(!("data-burn" in row(rail, id).attrs), `${id} has data-burn`);
    }
  },
  async the_row_carries_no_burn_text() {
    const rail = await run(quota(SEATS, []));
    assert.ok(!/burning/.test(row(rail, "claude_weekly").textContent), "burn text drawn in the row");
  },
  async drivers_render_one_line_each_with_label_and_pool() {
    const rail = await run(quota(SEATS, [{ label: "Claude Code", pool: "Claude", sessions: 2 }, { label: "Grok CLI", pool: "SuperGrok", sessions: 1 }]));
    const block = rail.all().find((n) => n.className === "drivers");
    assert.ok(block, "no drivers block");
    assert.ok(block.textContent.includes("Running now"));
    const lines = block.all().filter((n) => n.className === "drv").map((n) => n.textContent);
    assert.deepStrictEqual(lines, ["Claude Code (2) · Claude", "Grok CLI · SuperGrok"]);
  },
  async no_drivers_means_no_block() {
    for (const drivers of [[], undefined]) {
      const rail = await run(quota(SEATS, drivers));
      assert.ok(!rail.all().some((n) => n.className === "drivers"), "empty drivers drew a block");
    }
  }
};

(async () => {
  let failed = 0;
  for (const [name, fn] of Object.entries(tests)) {
    try { await fn(); console.log("ok " + name); }
    catch (e) { failed++; console.log("FAIL " + name + " " + e.message); }
  }
  console.log(`${Object.keys(tests).length - failed} passed, ${failed} failed`);
  process.exit(failed ? 1 : 0);
})();
