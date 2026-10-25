// Needs-you chips. Runs newtab.js against a DOM stub. No network.
// Run: node tests/needs_you_actions_test.js
"use strict";
const fs = require("fs"), path = require("path"), vm = require("vm"), assert = require("assert");
const SRC = process.env.NEWTAB_JS || path.join(__dirname, "..", "extension", "newtab.js");

class Node {
  constructor(tag, text) {
    this.tagName = tag; this.children = []; this.attrs = {}; this.className = "";
    this.style = { setProperty() {} }; this._text = text; this.hidden = false;
    this.value = ""; this.placeholder = ""; this._listeners = {};
  }
  get textContent() { return this._text != null ? this._text : this.children.map((c) => c.textContent).join(""); }
  set textContent(v) { this._text = String(v); this.children = []; }
  appendChild(c) { this.children.push(c); return c; }
  replaceChildren(...kids) { this._text = null; this.children = kids.filter((k) => k != null); }
  append(...kids) { kids.forEach((k) => this.appendChild(typeof k === "object" ? k : new Node("#text", String(k)))); }
  prepend(...kids) { this.children.unshift(...kids.map((k) => (typeof k === "object" ? k : new Node("#text", String(k))))); }
  insertBefore(c) { this.children.unshift(c); return c; }
  setAttribute(k, v) { this.attrs[k] = String(v); }
  getAttribute(k) { return k in this.attrs ? this.attrs[k] : null; }
  removeAttribute(k) { delete this.attrs[k]; }
  addEventListener(type, fn) { (this._listeners[type] = this._listeners[type] || []).push(fn); }
  click() { (this._listeners.click || []).forEach((fn) => fn({ preventDefault() {} })); }
  get classList() { const n = this; return { add() {}, remove() {}, toggle() {}, contains: (c) => n.className.split(/\s+/).includes(c) }; }
  querySelector() { return null; }
  querySelectorAll() { return []; }
  remove() {} focus() {} select() {} blur() {}
  all() { return [this].concat(...this.children.map((c) => (c.all ? c.all() : []))); }
}

function run(rows) {
  const copied = [];
  const fetches = [];
  const ids = {};
  const payload = {
    action_token: "fixture-token",
    cards: { needs_you: { fetched_at: "2026-10-24T12:00:00Z", error: null, data: rows } }
  };
  const document = {
    visibilityState: "hidden", title: "",
    getElementById: (id) => (ids[id] = ids[id] || new Node("div")),
    createElement: (t) => new Node(t),
    createTextNode: (t) => new Node("#text", t),
    addEventListener() {}, querySelector: () => null, querySelectorAll: () => [],
    body: new Node("body"), documentElement: new Node("html"),
    execCommand() { return false; }
  };
  const ctx = {
    document, location: { search: "" }, URLSearchParams, console, Date, Math, JSON,
    setTimeout, clearTimeout, setInterval: () => 0, clearInterval() {}, Promise,
    isNaN, Number, String, Array, Object,
    navigator: { clipboard: { writeText: (text) => { copied.push(String(text)); return Promise.resolve(); } } },
    fetch: (url, opts) => {
      fetches.push({ url: String(url), opts: opts || {} });
      if (String(url).indexOf("/actions/stage") !== -1) {
        return Promise.resolve({
          ok: true, status: 200,
          json: () => Promise.resolve({ ok: true, run_cmd: "echo staged-fixture", staged_path: "/tmp/staged.md" })
        });
      }
      return Promise.resolve({ ok: true, status: 200, json: () => Promise.resolve(payload) });
    },
    localStorage: { getItem: () => null, setItem() {}, removeItem() {} }
  };
  ctx.window = ctx;
  vm.runInNewContext(fs.readFileSync(SRC, "utf8"), ctx, { filename: SRC });
  return new Promise((resolve) => setTimeout(() => resolve({ needs: ids.needs, copied, fetches }), 30));
}

const base = {
  kind: "pr", id: "#12", title: "CI failed on the last push", detail: "unit",
  since: "2026-10-24T12:00:00Z", action: "logs", action_url: "https://example.test/checks/12"
};
const rows = [
  Object.assign({}, base, {
    row_key: "pr:rymiwe/orderly:#12:ci_fail", lane: "personal", repo: "rymiwe/orderly",
    actions: [{ id: "loop", label: "loop" }]
  }),
  Object.assign({}, base, {
    id: "#9", title: "Surface CI", row_key: "pr:sofware/surface:#9:ci_fail", lane: "sofware",
    repo: "sofware/surface", actions: [],
    wes: { id: "wes", label: "wes", copy_text: "[SOFware handoff] sofware/surface #9 Surface CI https://example.test/9 — reason: ci_fail" }
  }),
  Object.assign({}, base, {
    id: "#5", title: "Unclassified", row_key: "pr:both:#5:ci_fail", lane: "unknown",
    repo: "both", actions: []
  }),
  Object.assign({}, base, {
    id: "#4", title: "Loop blew up", row_key: "pr:rymiwe/orderly:#4:ci_fail", lane: "personal",
    actions: [{ id: "loop", label: "loop" }],
    last_action: { action: "loop", status: "failed", code: 1, since: "2026-10-24T12:00:00Z" }
  })
];

function buttons(needs) {
  return needs.all().filter((n) => n.tagName === "button");
}
function stageCalls(fetches) {
  return fetches.filter((f) => f.url.indexOf("/actions/stage") !== -1);
}

const tests = {
  async chips_for_personal_sofware_unknown_and_failed() {
    const { needs } = await run(rows);
    const text = needs.textContent;
    assert.ok(text.includes("personal"), text);
    assert.ok(text.includes("sofware"), text);
    assert.ok(text.includes("lane?"), text);
    assert.ok(text.includes("loop failed (exit 1)"), text);
    assert.ok(text.includes("wes"), text);
    const names = buttons(needs).map((b) => b.textContent);
    assert.ok(names.includes("loop"), names.join(","));
    assert.ok(names.includes("wes"), names.join(","));
    assert.ok(names.includes("lane?"), names.join(","));
    const sofware = needs.all().find((n) => n.attrs && n.attrs["data-lane"] === "sofware");
    const rowText = sofware ? needs.textContent : "";
    assert.ok(!rowText.includes("BLD"), rowText);
    const wes = buttons(needs).find((b) => b.attrs["data-action"] === "wes");
    assert.ok(!/BLD|grok -c/.test(wes.getAttribute("title")), wes.getAttribute("title"));
  },

  async personal_posts_and_copies_the_run_command() {
    const { needs, copied, fetches } = await run([rows[0]]);
    const loop = buttons(needs).find((b) => b.attrs["data-action"] === "loop");
    loop.click();
    await new Promise((r) => setTimeout(r, 30));
    const calls = stageCalls(fetches);
    assert.strictEqual(calls.length, 1);
    assert.strictEqual(calls[0].opts.method, "POST");
    assert.strictEqual(calls[0].opts.headers["Content-Type"], "application/json");
    assert.strictEqual(calls[0].opts.headers["X-Orderly-Token"], "fixture-token");
    assert.deepStrictEqual(JSON.parse(calls[0].opts.body), { row_key: rows[0].row_key, action: "loop" });
    assert.ok(copied.includes("echo staged-fixture"), copied.join("|"));
    assert.ok(needs.textContent.includes("staged (cmd copied)"), needs.textContent);
  },

  async sofware_copies_the_handoff_without_posting() {
    const { needs, copied, fetches } = await run([rows[1]]);
    buttons(needs).find((b) => b.attrs["data-action"] === "wes").click();
    await new Promise((r) => setTimeout(r, 30));
    assert.strictEqual(stageCalls(fetches).length, 0);
    assert.ok(copied.some((t) => t.startsWith("[SOFware handoff]")), copied.join("|"));
    assert.ok(!copied.some((t) => /BLD|grok -c|claude /.test(t)), copied.join("|"));
    assert.ok(!buttons(needs).some((b) => ["loop", "council", "draft", "resume"].includes(b.textContent)));
  },

  async unknown_lane_chip_does_not_post_or_copy() {
    const { needs, copied, fetches } = await run([rows[2]]);
    buttons(needs).find((b) => b.attrs["data-lane"] === "unknown").click();
    await new Promise((r) => setTimeout(r, 20));
    assert.strictEqual(stageCalls(fetches).length, 0);
    assert.deepStrictEqual(copied, []);
    assert.ok(needs.textContent.includes("Add repo/team to profile.json lanes"), needs.textContent);
  },

  async successful_stage_clears_stale_failure_and_shows_flash() {
    const row = Object.assign({}, rows[3], {
      last_action: { action: "loop", status: "failed", code: 1, since: "2026-10-24T12:00:00Z" }
    });
    const { needs, copied } = await run([row]);
    assert.ok(needs.all().some((n) => n.attrs && n.attrs["data-pill"] === "failed"), needs.textContent);
    buttons(needs).find((b) => b.attrs["data-action"] === "loop").click();
    await new Promise((r) => setTimeout(r, 30));
    assert.ok(copied.includes("echo staged-fixture"), copied.join("|"));
    const flash = needs.all().find((n) => n.attrs && n.attrs["data-flash"] === "1");
    assert.ok(flash, needs.textContent);
    assert.strictEqual(flash.textContent, "staged (cmd copied)");
    assert.ok(!needs.all().some((n) => n.attrs && n.attrs["data-pill"] === "failed"), needs.textContent);
  }
};

(async () => {
  let failed = 0;
  for (const [name, fn] of Object.entries(tests)) {
    try { await fn(); console.log("ok " + name); }
    catch (e) { failed++; console.log("FAIL " + name + " " + (e.stack || e.message)); }
  }
  console.log(`${Object.keys(tests).length - failed} passed, ${failed} failed`);
  process.exit(failed ? 1 : 0);
})();
