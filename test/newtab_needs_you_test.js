// Needs-you tiers and age badges, through the production new-tab script.
// Loads extension/newtab.js against a tiny DOM stub and lets its own render()
// run. No network and no jsdom.
// Run: node --test test/newtab_needs_you_test.js
"use strict";

const fs = require("fs");
const path = require("path");
const vm = require("vm");
const test = require("node:test");
const assert = require("node:assert/strict");

const SRC = path.join(__dirname, "..", "extension", "newtab.js");
const DAY = 24 * 60 * 60 * 1000;
const NOW = Date.parse("2026-10-21T12:00:00.000Z");

class Node {
  constructor(tag, text) {
    this.tagName = tag;
    this.children = [];
    this.attrs = {};
    this.className = "";
    this.style = { setProperty() {} };
    this._text = text;
    this.hidden = false;
    this.value = "";
    this.placeholder = "";
  }
  get textContent() {
    return this._text != null ? this._text : this.children.map((c) => c.textContent).join("");
  }
  set textContent(v) {
    this._text = String(v);
    this.children = [];
  }
  appendChild(c) {
    this.children.push(c);
    return c;
  }
  replaceChildren(...kids) {
    this._text = null;
    this.children = kids.filter((k) => k != null);
  }
  append(...kids) {
    kids.forEach((k) => this.appendChild(typeof k === "object" ? k : new Node("#text", String(k))));
  }
  prepend(...kids) {
    this.children.unshift(...kids.map((k) => (typeof k === "object" ? k : new Node("#text", String(k)))));
  }
  insertBefore(c) {
    this.children.unshift(c);
    return c;
  }
  setAttribute(k, v) {
    this.attrs[k] = String(v);
  }
  getAttribute(k) {
    return k in this.attrs ? this.attrs[k] : null;
  }
  removeAttribute(k) {
    delete this.attrs[k];
  }
  addEventListener(type, fn) {
    this._listeners = this._listeners || [];
    this._listeners.push({ type, fn });
  }
  dispatch(type) {
    const ev = { preventDefault() {}, target: this };
    (this._listeners || []).filter((l) => l.type === type).forEach((l) => l.fn(ev));
  }
  get classList() {
    const n = this;
    return {
      add() {},
      remove() {},
      toggle() {},
      contains: (c) => n.className.split(/\s+/).includes(c)
    };
  }
  querySelector() {
    return null;
  }
  querySelectorAll() {
    return [];
  }
  remove() {}
  focus() {}
  select() {}
  blur() {}
  all() {
    return [this].concat(...this.children.map((c) => (c.all ? c.all() : [])));
  }
}

// The page reads Date.now() inside render(). Pin it so an age of exactly
// 1d, 3d, or 7d is that many milliseconds, not a few late.
function withFrozenNow(source, nowMs) {
  return `(function (nowMs) {
    var RealDate = Date;
    function D(a, b, c, d, e, f, g) {
      var made;
      switch (arguments.length) {
        case 0: made = new RealDate(nowMs); break;
        case 1: made = new RealDate(a); break;
        case 2: made = new RealDate(a, b); break;
        case 3: made = new RealDate(a, b, c); break;
        case 4: made = new RealDate(a, b, c, d); break;
        case 5: made = new RealDate(a, b, c, d, e); break;
        case 6: made = new RealDate(a, b, c, d, e, f); break;
        default: made = new RealDate(a, b, c, d, e, f, g); break;
      }
      if (!(this instanceof D)) return String(made);
      return made;
    }
    D.now = function () { return nowMs; };
    D.parse = function (v) { return RealDate.parse(v); };
    D.UTC = RealDate.UTC;
    D.prototype = RealDate.prototype;
    Date = D;
  })(${nowMs});
` + source;
}

function isoBefore(ms) {
  return new Date(NOW - ms).toISOString();
}

async function renderNeeds(rows, extra, options) {
  extra = extra || {};
  options = options || {};
  const ids = {};
  const docListeners = [];
  const document = {
    visibilityState: "hidden",
    title: "",
    getElementById: (id) => (ids[id] = ids[id] || new Node("div")),
    createElement: (t) => new Node(t),
    createTextNode: (t) => new Node("#text", t),
    addEventListener(type, fn) {
      docListeners.push({ type, fn });
    },
    querySelector: () => null,
    querySelectorAll: () => [],
    body: new Node("body"),
    documentElement: new Node("html")
  };
  const ctx = {
    document,
    location: { search: "" },
    URLSearchParams,
    console,
    Math,
    JSON,
    Number,
    String,
    Array,
    Object,
    isNaN,
    Promise,
    setTimeout,
    clearTimeout,
    setInterval: () => 0,
    clearInterval() {},
    fetch: options.fetch || (() => Promise.resolve({
      ok: true,
      status: 200,
      json: () => Promise.resolve({
        cards: {
          needs_you: {
            fetched_at: new Date(NOW).toISOString(),
            error: null,
            data: rows,
            pending_keys: extra.pending_keys || [],
            snoozed: extra.snoozed || 0
          }
        }
      })
    })),
    localStorage: { getItem: () => null, setItem() {}, removeItem() {} }
  };
  ctx.window = ctx;
  const source = withFrozenNow(fs.readFileSync(SRC, "utf8"), NOW);
  vm.runInNewContext(source, ctx, { filename: SRC });
  await new Promise((resolve) => setTimeout(resolve, 30));
  ids.needs._fire = (type) => {
    docListeners.filter((l) => l.type === type).forEach((l) => l.fn({}));
  };
  return ids.needs;
}

function tiers(root) {
  return root.all().filter((n) => n.attrs && Object.prototype.hasOwnProperty.call(n.attrs, "data-tier"));
}

function groupLabel(block) {
  const label = block.all().find((n) => n.className === "group");
  assert.ok(label, "tier is missing its subheader");
  return label.textContent;
}

function row(root, title) {
  const found = root.all().filter((n) => n.tagName === "li" && n.textContent.includes(title));
  assert.equal(found.length, 1, `row ${title} in: ${root.textContent}`);
  return found[0];
}

function badge(root, title) {
  const ages = row(root, title).all().filter((n) => String(n.className || "").split(/\s+/).includes("age"));
  assert.equal(ages.length, 1, `age badge for ${title}`);
  return ages[0];
}

function assertBucket(root, title, bucket, label) {
  const age = badge(root, title);
  const classes = age.className.split(/\s+/);
  assert.ok(classes.includes(bucket), `${title} has ${age.className}, wanted ${bucket}`);
  if (label != null) assert.equal(age.textContent, label, title);
}

test("groups rows into tier order with counts and omits empty tiers", async () => {
  // Payload order is scrambled. The page groups by tier and keeps the order
  // the server sent inside a tier; it does not sort by age itself.
  const needs = await renderNeeds([
    { tier: "informational", id: "q", title: "Codex exhausted", since: isoBefore(3 * DAY), kind: "quota" },
    { tier: "direct_ask", id: "new-ask", title: "Newer ask", since: isoBefore(DAY), kind: "pr" },
    { tier: "blocked_on_me", id: "ci", title: "CI failed", since: isoBefore(10 * DAY), kind: "pr" },
    { tier: "direct_ask", id: "old-ask", title: "Older ask", since: isoBefore(6 * DAY), kind: "pr" },
    { tier: "informational", id: "box", title: "Box link", since: isoBefore(8 * DAY), kind: "machine" },
    { tier: "blocked_on_me", id: "perm", title: "Permission prompt", since: isoBefore(2 * 60 * 60 * 1000), kind: "agent" },
    { tier: "nope", id: "loose", title: "Loose note", since: isoBefore(4 * DAY) }
  ]);
  const blocks = tiers(needs);
  assert.deepEqual(blocks.map((b) => b.attrs["data-tier"]), ["direct_ask", "blocked_on_me", "informational"]);
  assert.deepEqual(blocks.map(groupLabel), ["Direct ask · 2", "Blocked on me · 2", "Informational · 3"]);
  assert.equal(needs.all().find((n) => n.className === "eyebrow").textContent, "Needs you · 7");
  assert.equal(needs.all().find((n) => n.className === "note").textContent, "priority, then oldest");
  assert.equal(blocks.some((b) => b.attrs["data-tier"] === "team_ask"), false);
  assert.equal(needs.textContent.includes("Team ask"), false);

  assert.ok(blocks[0].textContent.indexOf("Newer ask") < blocks[0].textContent.indexOf("Older ask"));
  assert.ok(blocks[1].textContent.indexOf("CI failed") < blocks[1].textContent.indexOf("Permission prompt"));
  assert.ok(blocks[2].textContent.indexOf("Codex exhausted") < blocks[2].textContent.indexOf("Box link"));
  assert.ok(blocks[2].textContent.indexOf("Box link") < blocks[2].textContent.indexOf("Loose note"));
  assert.ok(needs.textContent.indexOf("Older ask") < needs.textContent.indexOf("CI failed"));
  assert.ok(needs.textContent.indexOf("Permission prompt") < needs.textContent.indexOf("Codex exhausted"));
});

test("renders a team subheader only when that tier has a row", async () => {
  const needs = await renderNeeds([
    { tier: "team_ask", id: "t1", title: "Eng review", since: isoBefore(2 * DAY) },
    { tier: "informational", id: "q1", title: "Pool note", since: isoBefore(DAY), kind: "quota" }
  ]);
  const blocks = tiers(needs);
  assert.deepEqual(blocks.map((b) => b.attrs["data-tier"]), ["team_ask", "informational"]);
  assert.deepEqual(blocks.map(groupLabel), ["Team ask · 1", "Informational · 1"]);
  assert.equal(needs.all().find((n) => n.className === "eyebrow").textContent, "Needs you · 2");
  assert.equal(needs.textContent.includes("Direct ask"), false);
  assert.equal(needs.textContent.includes("Blocked on me"), false);
  assert.ok(needs.textContent.indexOf("Team ask") < needs.textContent.indexOf("Informational"));
  assert.ok(needs.textContent.indexOf("Eng review") < needs.textContent.indexOf("Pool note"));
});

test("age badges break at exactly one, three, and seven days", async () => {
  const rows = [
    ["age zero", 0, "age-lt-1d", "0m"],
    ["age just under 1d", DAY - 1, "age-lt-1d", null],
    ["age exact 1d", DAY, "age-1-3d", "1d"],
    ["age just under 3d", 3 * DAY - 1, "age-1-3d", null],
    ["age exact 3d", 3 * DAY, "age-3-7d", "3d"],
    ["age just under 7d", 7 * DAY - 1, "age-3-7d", null],
    ["age exact 7d", 7 * DAY, "age-gt-7d", "7d"],
    ["age past 7d", 7 * DAY + 1, "age-gt-7d", null]
  ].map(([title, ageMs, bucket, label]) => ({
    title,
    bucket,
    label,
    row: { tier: "informational", id: title, title, since: isoBefore(ageMs), kind: "quota" }
  }));
  rows.push({
    title: "still ahead",
    bucket: "age-lt-1d",
    label: "0m",
    row: { tier: "informational", id: "ahead", title: "still ahead", since: new Date(NOW + 60 * 1000).toISOString(), kind: "quota" }
  });
  rows.push({
    title: "missing since",
    bucket: "age-unknown",
    label: "",
    row: { tier: "informational", id: "missing", title: "missing since", kind: "quota" }
  });
  rows.push({
    title: "bad since",
    bucket: "age-unknown",
    label: "",
    row: { tier: "informational", id: "bad", title: "bad since", since: "not-a-time", kind: "quota" }
  });

  const needs = await renderNeeds(rows.map((c) => c.row));
  assert.deepEqual(tiers(needs).map(groupLabel), [`Informational · ${rows.length}`]);
  for (const c of rows) assertBucket(needs, c.title, c.bucket, c.label);
});

test("dims a team-ask row and keeps its tier count", async () => {
  const needs = await renderNeeds([
    {
      tier: "team_ask",
      dim: true,
      id: "#8",
      title: "platform, frontend asked for a review",
      since: isoBefore(2 * DAY),
      kind: "pr",
      clear_key: "github:acme/widgets#8:team",
      ask_from: "frontend,platform",
      action: "review",
      action_url: "https://example.test/acme/widgets/8"
    },
    {
      tier: "direct_ask",
      id: "#3",
      title: "Ada asked for your review",
      since: isoBefore(DAY),
      kind: "pr",
      clear_key: "github:acme/widgets#3:review",
      action: "review",
      action_url: "https://example.test/acme/widgets/3"
    }
  ]);
  const blocks = tiers(needs);
  assert.deepEqual(blocks.map(groupLabel), ["Direct ask · 1", "Team ask · 1"]);
  const team = row(needs, "platform, frontend asked for a review");
  assert.ok(team.className.split(/\s+/).includes("dim"), team.className);
  assert.equal(team.className.includes("dim"), true);
  assert.ok(needs.textContent.includes("platform"));
  assert.ok(needs.textContent.includes("frontend"));
  const direct = row(needs, "Ada asked for your review");
  assert.equal(direct.className.split(/\s+/).includes("dim"), false);
});

test("clicking an action hides the row and shows a pending marker", async () => {
  const needs = await renderNeeds([
    {
      tier: "direct_ask",
      id: "#4",
      title: "Review the latch",
      since: isoBefore(3 * 60 * 60 * 1000),
      kind: "pr",
      clear_key: "github:acme/widgets#4:review",
      action: "review",
      action_url: "https://example.test/acme/widgets/4"
    },
    {
      tier: "informational",
      id: "q",
      title: "Codex exhausted",
      since: isoBefore(DAY),
      kind: "quota",
      clear_key: "quota:codex"
    }
  ]);
  assert.equal(needs.textContent.includes("pending"), false);
  const act = row(needs, "Review the latch").all().find((n) => n.className === "act");
  assert.ok(act, "action control");
  act.dispatch("click");
  assert.equal(needs.textContent.includes("Review the latch"), false);
  const mark = needs.all().find((n) => n.className === "pending-mark");
  assert.ok(mark, "pending marker");
  assert.match(mark.textContent, /pending · 1/);
  assert.deepEqual(tiers(needs).map(groupLabel), ["Informational · 1"]);
  assert.equal(needs.all().find((n) => n.className === "eyebrow").textContent, "Needs you · 1");
});

test("renders snoozed and pending state without counting hidden rows in a tier", async () => {
  const needs = await renderNeeds([
    {
      tier: "direct_ask",
      id: "#4",
      title: "Hidden ask",
      since: isoBefore(DAY),
      kind: "pr",
      clear_key: "github:acme/widgets#4:review"
    },
    {
      tier: "direct_ask",
      id: "#5",
      title: "Visible ask",
      since: isoBefore(2 * DAY),
      kind: "pr",
      clear_key: "github:acme/widgets#5:review"
    },
    {
      tier: "team_ask",
      dim: true,
      id: "#9",
      title: "platform asked for a review",
      since: isoBefore(DAY),
      kind: "pr",
      clear_key: "github:acme/widgets#9:team"
    }
  ], { pending_keys: ["github:acme/widgets#4:review"], snoozed: 2 });
  assert.equal(needs.textContent.includes("Hidden ask"), false);
  assert.ok(needs.textContent.includes("Visible ask"));
  assert.ok(needs.textContent.includes("platform asked for a review"));
  const pending = needs.all().find((n) => n.className === "pending-mark");
  const snoozed = needs.all().find((n) => n.className === "snooze-mark");
  assert.equal(pending.textContent, "pending · 1");
  assert.equal(snoozed.textContent, "snoozed · 2");
  assert.deepEqual(tiers(needs).map(groupLabel), ["Direct ask · 1", "Team ask · 1"]);
  assert.equal(needs.all().find((n) => n.className === "eyebrow").textContent, "Needs you · 2");
  const team = row(needs, "platform asked for a review");
  assert.ok(team.className.split(/\s+/).includes("dim"));
});

test("a poll started before the click does not bring the row back", async () => {
  const rowData = {
    tier: "direct_ask",
    id: "#4",
    title: "Review the latch",
    since: isoBefore(3 * 60 * 60 * 1000),
    kind: "pr",
    clear_key: "github:acme/widgets#4:review",
    action: "review",
    action_url: "https://example.test/acme/widgets/4"
  };
  const cards = {
    ok: true,
    status: 200,
    json: () => Promise.resolve({
      cards: {
        needs_you: {
          fetched_at: new Date(NOW).toISOString(),
          error: null,
          data: [rowData],
          pending_keys: [],
          snoozed: 0
        }
      }
    })
  };
  let cardsCalls = 0;
  let releaseStale;
  const needs = await renderNeeds([rowData], {}, {
    fetch: (_url, opts) => {
      if (opts && opts.method === "POST") {
        assert.equal(opts.keepalive, true);
        return Promise.resolve({ ok: true, status: 204, json: () => Promise.resolve({}) });
      }
      cardsCalls += 1;
      if (cardsCalls === 1) return Promise.resolve(cards);
      return new Promise((resolve) => {
        releaseStale = () => resolve(cards);
      });
    }
  });
  assert.ok(needs.textContent.includes("Review the latch"));
  needs._fire("visibilitychange");
  assert.equal(cardsCalls, 2);
  const act = row(needs, "Review the latch").all().find((n) => n.className === "act");
  act.dispatch("click");
  await new Promise((resolve) => setTimeout(resolve, 20));
  assert.equal(needs.textContent.includes("Review the latch"), false);
  releaseStale();
  await new Promise((resolve) => setTimeout(resolve, 20));
  assert.equal(needs.textContent.includes("Review the latch"), false, "stale poll restored the row");
  assert.match(needs.all().find((n) => n.className === "pending-mark").textContent, /pending · 1/);
});
