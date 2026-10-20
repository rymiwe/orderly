// The machines card draws no Grok Bot link indicator. Runs newtab.js against a
// tiny DOM stub with one /cards payload. No network, no browser.
// Run: node tests/machines_card_test.js
"use strict";
const fs = require("fs"), path = require("path"), vm = require("vm"), assert = require("assert");
const SRC = process.env.NEWTAB_JS || path.join(__dirname, "..", "extension", "newtab.js");

class Node {
  constructor(tag, text) { this.tagName = tag; this.children = []; this.attrs = {}; this.className = ""; this.style = { setProperty() {} }; this._text = text; this.hidden = false; this.value = ""; this.placeholder = ""; }
  get textContent() { return this._text != null ? this._text : this.children.map((c) => c.textContent).join(" "); }
  set textContent(v) { this._text = String(v); this.children = []; }
  appendChild(c) { this.children.push(c); return c; }
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
  return new Promise((r) => setTimeout(() => r(ids.fleet), 20));
}

const now = new Date().toISOString();
const machine = (o) => Object.assign({ id: "surface", label: "Surface", expected_always_on: true, link: "connected",
  link_as_of: now, heartbeat_last: now, heartbeat_age_s: 120, heartbeat: "live", note: null }, o);
const payload = { cards: { machines: { fetched_at: now, error: null, data: { cache_present: true, cache_as_of: now, machines: [
  machine({}),
  machine({ id: "BLD", label: "BLD", link: "disconnected", heartbeat_age_s: 1800, heartbeat: "dead" }),
  machine({ id: "mba", label: "mba", expected_always_on: false, link: "unknown", link_stale: true, heartbeat_age_s: null, heartbeat: "unknown" })
] } } } };

const tests = {
  async machines_card_keeps_label_heartbeat_and_always_on_chip() {
    const fleet = await run(payload);
    const text = fleet.textContent;
    for (const want of ["Machines", "Surface", "BLD", "mba", "hb 2m", "not always-on"]) assert.ok(text.includes(want), `missing ${want}: ${text}`);
    assert.ok(fleet.all().some((n) => n.className === "hb dead"), "BLD heartbeat is not marked dead");
  },
  async machines_card_draws_no_bot_link_indicator() {
    const fleet = await run(payload);
    const text = fleet.textContent;
    for (const bad of ["connected", "disconnected", "link unknown", "bot pool empty"]) assert.ok(!text.includes(bad), `link text "${bad}" drawn: ${text}`);
    const machines = fleet.all().filter((n) => /^machine\b/.test(n.className));
    assert.strictEqual(machines.length, 3);
    for (const m of machines) {
      assert.ok(!m.all().some((n) => /\bchip (good|crit)\b/.test(n.className)), "colored link chip drawn");
      assert.ok(!/link/i.test(m.attrs.title || ""), `link in tooltip: ${m.attrs.title}`);
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
