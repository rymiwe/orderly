// Quota rail burn outline, status dot, and running-now list. Runs newtab.js
// against the same tiny DOM stub as machines_card_test.js (plus first/lastChild,
// which the rail uses) with one /cards payload. No network.
// The dot colour is reached the same way as the other helpers in this file:
// render a seat and read the DOM. newtab.js is an IIFE and exports nothing.
// No existing assertion checked the row keyframes or the strong row's thicker
// left edge, so none of those assertions were rewritten. The CSS checks below
// cover that removal.
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
const detail = (r) => r.all().find((n) => n.className === "v");
const dotOf = (r) => {
  const v = detail(r);
  return v ? v.all().find((n) => n.attrs && Object.prototype.hasOwnProperty.call(n.attrs, "data-dot")) : null;
};
const slotOf = (r) => {
  const v = detail(r);
  return v ? v.all().find((n) => n.className && n.className.split(/\s+/).includes("dot-none")) : null;
};
// resets_at that puts `elapsed` percent of windowS behind now. A few
// milliseconds of render delay does not move the percent.
function resetsForElapsed(elapsed, windowS = 604800) {
  return new Date(now.getTime() + ((100 - elapsed) / 100) * windowS * 1000).toISOString();
}
function painted(o) {
  return seat(Object.assign({
    resets_at: resetsForElapsed(o.elapsed == null ? 50 : o.elapsed),
    window_s: 604800,
    verified_at: now.toISOString()
  }, o));
}

const HTML = fs.readFileSync(path.join(__dirname, "..", "extension", "newtab.html"), "utf8");
const CSS = HTML.replace(/\/\*[\s\S]*?\*\//g, "");

function cssRules(src) {
  const rules = [];
  let i = 0;
  const skip = () => { while (i < src.length && /\s/.test(src[i])) i++; };
  while (i < src.length) {
    skip();
    if (i >= src.length) break;
    const brace = src.indexOf("{", i);
    if (brace < 0) break;
    const head = src.slice(i, brace).trim();
    i = brace + 1;
    let depth = 1;
    const start = i;
    while (i < src.length && depth) {
      if (src[i] === "{") depth++;
      else if (src[i] === "}") depth--;
      i++;
    }
    const body = src.slice(start, i - 1);
    if (head.startsWith("@media")) rules.push({ at: head, nested: cssRules(body) });
    else if (!head.startsWith("@")) rules.push({ sel: head, body });
  }
  return rules;
}
function walkRules(rules, fn) {
  rules.forEach((r) => { if (r.nested) walkRules(r.nested, fn); else fn(r); });
}
// A row selector's rightmost compound is the seat itself (or its pseudo),
// not a descendant such as `.seat .v .dot`.
function isSeatRowSelector(sel) {
  return sel.split(",").some((part) => {
    const bits = part.trim().split(/\s*[>+~]\s*|\s+/).filter(Boolean);
    return bits.length > 0 && /^\.seat(?![-\w])/.test(bits[bits.length - 1]);
  });
}
function reducedMotionBlocks(css) {
  const out = [];
  const re = /@media\s*\(\s*prefers-reduced-motion:\s*reduce\s*\)\s*\{/g;
  let m;
  while ((m = re.exec(css))) {
    let i = m.index + m[0].length;
    let depth = 1;
    const start = i;
    while (i < css.length && depth) {
      if (css[i] === "{") depth++;
      else if (css[i] === "}") depth--;
      i++;
    }
    out.push(css.slice(start, i - 1));
  }
  return out;
}

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
  },
  async dot_colour_follows_pace_caps_and_burn() {
    const cases = [
      { name: "ahead", seat: "a", pace: "ahead", burn: "soft", percent: 20, text: "20%", elapsed: 50, color: "red", title: "in use · ahead of pace" },
      { name: "caps early", seat: "b", pace: "under", burn: "soft", percent: 70, text: "70%", elapsed: 40, color: "red", title: "in use · caps early" },
      { name: "full", seat: "c", pace: "under", burn: "soft", percent: 100, text: "100%", elapsed: 50, color: "red", title: "in use · full" },
      { name: "on pace", seat: "d", pace: "on", burn: "soft", percent: 40, text: "40%", elapsed: 50, color: "yellow", title: "in use · on pace" },
      { name: "under strong", seat: "e", pace: "under", burn: "strong", percent: 20, text: "20%", elapsed: 50, color: "yellow", title: "in use · near pace" },
      { name: "under soft", seat: "f", pace: "under", burn: "soft", percent: 20, text: "20%", elapsed: 50, color: "green", title: "in use · under pace" },
      // Empty pace falls back to the meter's split. elapsed 5 skips caps
      // (the projection is ignored in the first tenth of the window).
      { name: "unknown pace over elapsed", seat: "g", pace: "", burn: "soft", percent: 8, text: "8%", elapsed: 5, color: "yellow", title: "in use · ahead of the window" },
      { name: "unknown pace under elapsed", seat: "h", pace: "", burn: "soft", percent: 20, text: "20%", elapsed: 50, color: "green", title: "in use · under pace" },
      { name: "unknown pace strong", seat: "i", pace: "", burn: "strong", percent: 20, text: "20%", elapsed: 50, color: "yellow", title: "in use · near pace" }
    ];
    const seats = cases.map((c) => painted({
      seat: c.seat, label: c.name, pace: c.pace, burn: c.burn, percent: c.percent, text: c.text, elapsed: c.elapsed,
      vendor: "claude", subscription: "claude"
    }));
    const rail = await run(quota(seats, []));
    for (const c of cases) {
      const r = row(rail, c.seat);
      const dot = dotOf(r);
      assert.ok(dot, `${c.name} has no dot`);
      assert.strictEqual(dot.attrs["data-dot"], c.color, c.name);
      assert.strictEqual(dot.className, "dot dot-" + c.color, c.name);
      assert.strictEqual(dot.attrs.title, c.title, c.name);
      assert.strictEqual(dot.attrs["aria-hidden"], "true", c.name);
      assert.strictEqual(r.attrs["data-burn"], c.burn, c.name);
      const v = detail(r);
      assert.strictEqual(v.children[0], dot, `${c.name} dot is not beside the percentage`);
      assert.ok(String(v.children[1].textContent).includes("%"), `${c.name} percent missing`);
      if (c.name === "caps early") assert.ok(/caps /.test(v.textContent), v.textContent);
    }
  },
  async inactive_percent_rows_reserve_an_empty_slot() {
    const seats = [
      painted({ seat: "idle", label: "Idle", burn: "none", pace: "under", percent: 30, text: "30%", elapsed: 50 }),
      painted({ seat: "quiet", label: "Quiet", burn: "soft", status: "unknown", percent: null, text: "unknown", pace: "ahead", elapsed: 50 }),
      painted({ seat: "gone", label: "Gone", burn: "strong", status: "absent", percent: null, text: "not on this plan", pace: "ahead", elapsed: 50 })
    ];
    const rail = await run(quota(seats, []));
    const idle = row(rail, "idle");
    const slot = slotOf(idle);
    assert.ok(slot, "idle percent row has no slot");
    assert.strictEqual(slot.className, "dot dot-none");
    assert.strictEqual(slot.attrs["aria-hidden"], "true");
    assert.ok(!("title" in slot.attrs), "placeholder has a title");
    assert.ok(!("data-dot" in slot.attrs), "placeholder is a coloured dot");
    assert.strictEqual(dotOf(idle), undefined, "idle drew a coloured dot");
    const v = detail(idle);
    assert.strictEqual(v.children[0], slot, "slot is not beside the percentage");
    assert.strictEqual(slot.textContent, "");
    assert.ok(String(v.textContent).includes("30%"), v.textContent);
    assert.ok(!/in use|burning/.test(v.textContent), v.textContent);
    // The detail tooltip is the row text. The empty slot adds no words to it.
    assert.strictEqual(v.title, v.textContent);
    assert.ok(String(v.title).includes("30%"), v.title);
    assert.ok(!/in use|burning/.test(v.title), v.title);
    assert.ok(!("data-burn" in idle.attrs), "idle has data-burn");
    for (const id of ["quiet", "gone"]) {
      const r = row(rail, id);
      assert.ok(r, id);
      assert.strictEqual(dotOf(r), undefined, `${id} drew a dot`);
      assert.strictEqual(slotOf(r), undefined, `${id} reserved a slot`);
      assert.ok(!("data-burn" in r.attrs), `${id} has data-burn`);
    }
    assert.match(CSS, /\.dot-none\{[^}]*visibility:\s*hidden/);
    assert.ok(!/\.dot\.dot-none[^{]*\{[^}]*dot-breathe/.test(CSS), "the empty slot breathes");
  },
  async every_burning_row_gets_a_dot_not_only_the_next_host() {
    const seats = [
      painted({ seat: "claude_weekly", label: "Claude", burn: "soft", pace: "under", percent: 20, text: "20%", elapsed: 50, vendor: "claude", subscription: "claude" }),
      painted({ seat: "cursor_models", label: "Cursor Models", burn: "soft", pace: "under", percent: 25, text: "25%", elapsed: 50, vendor: "cursor", subscription: "cursor" })
    ];
    const rail = await run(quota(seats, []));
    // host_suggestion is null in quota(): neither row is the next host.
    for (const id of ["claude_weekly", "cursor_models"]) {
      const dot = dotOf(row(rail, id));
      assert.ok(dot, id);
      assert.strictEqual(dot.attrs["data-dot"], "green", id);
    }
  },
  async the_dot_breathes_for_two_seconds_and_the_row_does_not() {
    assert.match(CSS, /animation:\s*dot-breathe\s+2s\s+ease-in-out\s+infinite\s+alternate/);
    assert.match(CSS, /@keyframes\s+dot-breathe\s*\{/);
    assert.ok(!/burn-breathe/.test(CSS), "row breathe keyframes still present");
    assert.ok(!/border-left-width\s*:\s*6px/.test(CSS), "strong row still thickens the left bar");
    assert.ok(!/padding-left\s*:\s*5px/.test(CSS), "strong row still changes padding");
    const blocks = reducedMotionBlocks(CSS);
    assert.ok(blocks.length > 0, "no prefers-reduced-motion block");
    assert.ok(blocks.some((b) => /\.dot[\s\S]*?\{[\s\S]*?animation\s*:\s*none/.test(b)),
      "reduced motion does not set animation:none on the dot");
    const animatedRows = [];
    walkRules(cssRules(CSS), (r) => {
      if (/animation\s*:/.test(r.body) && isSeatRowSelector(r.sel)) animatedRows.push(r.sel);
    });
    assert.deepStrictEqual(animatedRows, []);
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
