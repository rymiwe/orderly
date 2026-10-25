(function () {
  var portParam = new URLSearchParams(location.search).get("port") || "";
  var CARDS_PORT = /^\d+$/.test(portParam) ? portParam : "5180";
  var CARDS_URL = "http://127.0.0.1:" + CARDS_PORT + "/cards";
  var STAGE_URL = "http://127.0.0.1:" + CARDS_PORT + "/actions/stage";
  var POLL_MS = 5000;
  // Dot colour is burn rate only, in percentage points per hour. Green below
  // 5, yellow from 5 up to 15, red at 15 and above.
  var DOT_YELLOW_PPH = 5;
  var DOT_RED_PPH = 15;
  // 2s ease-in-out alternate is a 4s round trip. A negative delay of this
  // modulus puts a rebuilt dot on the frame the old one had reached.
  var DOT_PHASE_MS = 4000;
  var SEATS = [
    { seat: "claude_weekly", label: "Claude · weekly", note: "seat-usage has no value" },
    { seat: "claude_fable", label: "Claude · Fable slice", note: "seat-usage has no value" },
    { seat: "codex", label: "Codex · weekly", note: "seat-usage has no value" },
    { seat: "cursor_models", label: "Cursor · Cursor Models", note: "seat-usage has no value" },
    { seat: "cursor_other", label: "Cursor · Other Models", note: "seat-usage has no value" },
    { seat: "grokbot", label: "Grok Bot · weekly", note: "seat-usage has no value" },
    { seat: "supergrok", label: "SuperGrok · weekly", note: "seat-usage has no value" },
    { seat: "muse", label: "Muse · weekly", note: "seat-usage has no value" }
  ];

  // Model families each pool can serve, in each family's order of preference.
  // A view of the routing written in ~/.claude/CLAUDE.md; seat-usage --route
  // still decides a launch. Claude's 5h limit rides on the weekly row.
  var FAMILIES = [
    { name: "Fable", sources: ["claude_fable", "claude_weekly", "cursor_other"] },
    { name: "Opus", sources: ["claude_weekly", "cursor_other"] },
    { name: "Astra", sources: ["codex"] },
    { name: "Sol", sources: ["codex", "cursor_other"] },
    { name: "Grok", sources: ["cursor_models", "supergrok"] },
    { name: "Grok Bot", sources: ["grokbot"] },
    // Wonder full is the frontier on the Muse seat, the way Astra is on ChatGPT.
    // Wonder is the other model on that seat, the way Sol is. Display only;
    // seat-usage still decides a launch.
    { name: "Wonder full", sources: ["muse"] },
    { name: "Wonder", sources: ["muse"] }
  ];
  // FAMILIES plus the families a server row names itself (rows built from
  // quartermaster's seat rows, whose families come from config/pools.json).
  // A row joins the end of a family's order; a new family joins the end.
  function families() {
    var c = card("quota");
    var out = FAMILIES.map(function (f) { return { name: f.name, sources: f.sources.slice() }; });
    ((c && c.data && c.data.seats) || []).forEach(function (s) {
      (Array.isArray(s.families) ? s.families : []).forEach(function (name) {
        var f = out.filter(function (x) { return x.name === name; })[0];
        if (!f) out.push(f = { name: String(name), sources: [] });
        if (f.sources.indexOf(s.seat) === -1) f.sources.push(s.seat);
      });
    });
    return out;
  }
  var METERED = { cursor_other: true };
  // SuperGrok is builder capacity only: no hosting, no chairing (CLAUDE.md, 2026-10-08).
  var BUILDER_ONLY = { supergrok: true };
  var famPinned = null;
  var famPreview = null;

  var payload = null;
  var fetchError = null;
  // Click feedback for this page load. Failure pills come from the server and
  // outlive a reload; this map does not.
  var stagedFlash = {};
  var query = "";
  var idleOpen = false;
  var otherOpen = false;
  var teamOpen = false;
  var prTab = "mine";
  var pollTimer = null;
  var loadSeq = 0;

  var qEl = document.getElementById("q");
  var metaEl = document.getElementById("meta");
  var needsEl = document.getElementById("needs");
  var wtEl = document.getElementById("col-wt");
  var prEl = document.getElementById("col-pr");
  var linEl = document.getElementById("col-lin");
  var fleetEl = document.getElementById("fleet");
  var railEl = document.getElementById("rail");

  // Every href on this page comes from the GitHub or Linear API. Nothing else
  // is a link, so anything that is not http(s) renders inert rather than
  // reaching the page as a javascript: URL.
  function safeHref(url) {
    var s = String(url == null ? "" : url).trim();
    return /^https?:\/\//i.test(s) ? s : "#";
  }

  function el(tag, attrs) {
    var node = document.createElement(tag);
    var i, k, v, kids, child;
    if (attrs) {
      for (k in attrs) {
        if (!Object.prototype.hasOwnProperty.call(attrs, k)) continue;
        v = attrs[k];
        if (v == null || v === false) continue;
        if (k === "class") node.className = v;
        else if (k === "hidden") node.hidden = !!v;
        else if (k === "text") node.textContent = String(v);
        else if (k === "href") node.setAttribute("href", safeHref(v));
        else node.setAttribute(k, v === true ? "" : String(v));
      }
    }
    kids = Array.prototype.slice.call(arguments, 2);
    for (i = 0; i < kids.length; i++) {
      child = kids[i];
      if (child == null || child === false) continue;
      if (Array.isArray(child)) {
        child.forEach(function (c) {
          if (c == null || c === false) return;
          node.appendChild(typeof c === "string" || typeof c === "number" ? document.createTextNode(String(c)) : c);
        });
      } else if (typeof child === "string" || typeof child === "number") {
        node.appendChild(document.createTextNode(String(child)));
      } else {
        node.appendChild(child);
      }
    }
    return node;
  }

  function card(name) {
    return payload && payload.cards ? payload.cards[name] : null;
  }

  function hasData(c) {
    return !!(c && c.data != null);
  }

  function formatAge(then, now) {
    var t;
    if (!then) return "";
    t = Date.parse(then);
    if (isNaN(t)) return "";
    return formatSpan((now - t) / 1000);
  }

  // A duration in seconds as "2d", "1d 4h", "3h 10m" or "5m".
  function formatSpan(secs) {
    var s, d, h, m;
    s = Math.max(0, Math.floor(secs));
    d = Math.floor(s / 86400);
    h = Math.floor((s % 86400) / 3600);
    m = Math.floor((s % 3600) / 60);
    if (d >= 2) return d + "d";
    if (d >= 1) return h ? d + "d " + h + "h" : d + "d";
    if (h >= 1) return m ? h + "h " + m + "m" : h + "h";
    return m + "m";
  }

  function formatFresh(then, now) {
    var t, s;
    if (!then) return "";
    t = Date.parse(then);
    if (isNaN(t)) return "";
    s = Math.max(0, Math.floor((now - t) / 1000));
    if (s < 60) return s + "s";
    return formatAge(then, now);
  }

  function clock(now) {
    var wd = new Intl.DateTimeFormat("en-US", { weekday: "short" }).format(now);
    var hm = new Intl.DateTimeFormat("en-GB", { hour: "2-digit", minute: "2-digit", hour12: false }).format(now);
    return wd + " " + hm;
  }

  function matches(hay, q) {
    if (!q) return true;
    return String(hay).toLowerCase().indexOf(q.toLowerCase()) !== -1;
  }

  function wtHay(row) {
    var bits = [row.name, row.branch, row.repo];
    if (row.pr && row.pr.number != null) {
      bits.push(String(row.pr.number), "#" + row.pr.number);
    }
    if (row.app_port != null) bits.push(String(row.app_port), ":" + row.app_port);
    if (row.db_port != null) bits.push(String(row.db_port), ":" + row.db_port);
    return bits.filter(Boolean).join(" ");
  }

  function needHay(row) {
    return [row.id, row.title, row.detail, row.action, row.worktree].filter(Boolean).join(" ");
  }

  function prHay(row) {
    return ["#" + row.number, String(row.number), row.title, row.repo].filter(Boolean).join(" ");
  }

  function linHay(row) {
    return [row.id || row.issue_id, row.title].filter(Boolean).join(" ");
  }

  function agentActive(agent) {
    return !!agent && (agent.state === "working" || agent.state === "waiting" || agent.state === "unconfirmed");
  }

  function isRunning(row) {
    return (row.agents || []).some(agentActive);
  }

  function sourceDot(c) {
    if (!c || c.data == null) return "off";
    if (c.error && c.error !== "no data yet") return "warn";
    return "";
  }

  function latestFetched() {
    var names = ["worktrees", "agents", "needs_you", "prs", "linear", "quota", "machines"];
    var best = null, i, c, t;
    for (i = 0; i < names.length; i++) {
      c = card(names[i]);
      if (!c || !c.fetched_at) continue;
      t = Date.parse(c.fetched_at);
      if (isNaN(t)) continue;
      if (best == null || t > best) best = t;
    }
    return best;
  }

  function staleBits(c) {
    var bits = [];
    if (!c) return bits;
    if (c.error && c.error !== "no data yet") bits.push(c.error);
    if (c.error && c.error !== "no data yet" && c.fetched_at) {
      bits.push(formatAge(c.fetched_at, Date.now()) + " ago");
    }
    return bits;
  }

  function agentChip(agent) {
    var cls = "chip";
    if (agent.state === "waiting") cls += " warn";
    else if (agent.state === "unconfirmed") cls += " crit";
    return el("span", { class: cls }, (agent.tool || "?") + " · " + (agent.state || "?"));
  }

  function prLabel(pr) {
    var t;
    if (!pr || pr.number == null) return "";
    t = "PR #" + pr.number;
    if (pr.draft) t += " draft";
    if (pr.state && pr.state !== "OPEN") t += " " + String(pr.state).toLowerCase();
    return t;
  }

  function prChip(pr) {
    var t;
    if (!pr || pr.number == null) return null;
    t = "#" + pr.number;
    if (pr.draft) t += " draft";
    if (pr.state && pr.state !== "OPEN") t += " " + String(pr.state).toLowerCase();
    return el("span", { class: "chip" }, t);
  }

  function copyText(text) {
    if (navigator.clipboard && navigator.clipboard.writeText) {
      return navigator.clipboard.writeText(text).catch(function () { fallbackCopy(text); });
    }
    fallbackCopy(text);
    return Promise.resolve();
  }

  function fallbackCopy(text) {
    var ta = el("textarea", { "aria-hidden": "true" });
    ta.value = text;
    ta.style.position = "fixed";
    ta.style.left = "-9999px";
    document.body.appendChild(ta);
    ta.select();
    try { document.execCommand("copy"); } catch (e) {}
    ta.remove();
  }

  function pruneChip(cmd) {
    var b = el("button", { class: "chip", type: "button", title: cmd }, "git worktree remove");
    b.addEventListener("click", function (e) {
      e.preventDefault();
      copyText(cmd);
    });
    return b;
  }

  function serverSub(row) {
    if (row.app_port != null) return "app :" + row.app_port + " · db :" + row.db_port;
    return "no server";
  }

  function wtTitle(row) {
    if (row.branch) return row.branch;
    if (row.detached) return "detached HEAD" + (row.head ? " " + row.head : "");
    return "";
  }

  function runningRow(row) {
    var chips = (row.agents || []).map(agentChip);
    var sub = [
      el("span", { class: "agent" }, el("span", { class: "k" }, row.repo || ""), " ", serverSub(row))
    ];
    (row.pings || []).forEach(function (p) {
      var name = String(p.path || "").replace(/^\//, "");
      if (!name) return;
      sub.push(el("span", { class: p.ok ? "ok" : "bad" }, name));
    });
    var seen = {};
    var details = [];
    if (row.pr) sub.push(el("span", null, prLabel(row.pr)));
    (row.agents || []).forEach(function (a) {
      var line;
      if (!agentActive(a) || !a.detail) return;
      line = (a.tool || "?") + " · " + a.detail;
      if (seen[line]) return;
      seen[line] = true;
      details.push(el("span", { class: "detail" }, line));
    });
    return el("div", { class: "row wt" },
      el("span", { class: "id" }, row.name || ""),
      el("span", { class: "title" }, wtTitle(row)),
      el("span", { class: "chips" }, chips),
      el("span", { class: "sub" }, sub),
      details
    );
  }

  function idleRow(row) {
    var kids = [
      el("span", { class: "id dim" }, row.name || ""),
      el("span", { class: "title" }, wtTitle(row)),
      el("span", { class: "chips" }, prChip(row.pr))
    ];
    if (row.app_port != null || (row.pings && row.pings.length)) {
      var sub = [
        el("span", { class: "agent" }, el("span", { class: "k" }, row.repo || ""), " ", serverSub(row))
      ];
      (row.pings || []).forEach(function (p) {
        var name = String(p.path || "").replace(/^\//, "");
        if (!name) return;
        sub.push(el("span", { class: p.ok ? "ok" : "bad" }, name));
      });
      kids.push(el("span", { class: "sub" }, sub));
    }
    return el("div", { class: "row wt" }, kids);
  }

  function pruneRow(row) {
    var title = wtTitle(row);
    if (row.prune_reason) title = title ? title + " · " + row.prune_reason : row.prune_reason;
    return el("div", { class: "row wt prune" },
      el("span", { class: "id dim" }, row.name || ""),
      el("span", { class: "title" }, title),
      el("span", { class: "chips" }, row.prune_command ? pruneChip(row.prune_command) : null)
    );
  }

  function emptyNote(text) {
    return el("div", { class: "note" }, text || "no data yet");
  }

  function renderMeta(now) {
    var gh = card("prs") || card("worktrees");
    var linear = card("linear");
    var grok = card("agents");
    var fetched = latestFetched();
    var fresh = fetched != null ? formatFresh(new Date(fetched).toISOString(), now) : "";
    var kids = [el("span", null, clock(now))];
    function src(label, cls) {
      return el("span", null, el("span", { class: "dot" + (cls ? " " + cls : "") }), label);
    }
    kids.push(src("gh", sourceDot(gh)));
    kids.push(src("linear", sourceDot(linear)));
    kids.push(src("grok", sourceDot(grok)));
    kids.push(src("fleet", sourceDot(card("machines"))));
    if (fetchError && !payload) kids.push(el("span", null, "no data yet"));
    else if (fetchError) kids.push(el("span", null, fetchError));
    else if (fresh) kids.push(el("span", null, "refreshed " + fresh + " ago"));
    else kids.push(el("span", null, "no data yet"));
    metaEl.replaceChildren.apply(metaEl, kids);
  }

  function laneChip(row) {
    if (row.lane === "personal") return el("span", { class: "chip", "data-lane": "personal" }, "personal");
    if (row.lane === "sofware") return el("span", { class: "chip", "data-lane": "sofware" }, "sofware");
    if (row.lane === "unknown") {
      var b = el("button", {
        class: "chip inert", type: "button", "data-lane": "unknown",
        title: "Add repo/team to profile.json lanes"
      }, "lane?");
      b.addEventListener("click", function (e) {
        e.preventDefault();
        stagedFlash[row.row_key] = "Add repo/team to profile.json lanes";
        render();
      });
      return b;
    }
    return null;
  }

  function wesChip(row) {
    var text = row.wes && row.wes.copy_text;
    var b = el("button", { class: "chip", type: "button", "data-action": "wes", title: text || "" }, "wes");
    b.addEventListener("click", function (e) {
      e.preventDefault();
      if (!text) return;
      copyText(text);
      stagedFlash[row.row_key] = "copied";
      render();
    });
    return b;
  }

  function stageChip(row, action) {
    var id = action && action.id;
    var b = el("button", { class: "chip", type: "button", "data-action": id || "" }, (action && action.label) || id || "");
    b.addEventListener("click", function (e) {
      e.preventDefault();
      if (!id) return;
      postStage(row, id);
    });
    return b;
  }

  // Copies the run command the server returns. Does not run it.
  function postStage(row, actionId) {
    var token = payload && payload.action_token ? String(payload.action_token) : "";
    fetch(STAGE_URL, {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-Orderly-Token": token },
      body: JSON.stringify({ row_key: row.row_key, action: actionId })
    }).then(function (res) {
      return res.json().then(function (body) {
        return { ok: res.ok, body: body || {} };
      }, function () { return { ok: false, body: {} }; });
    }).then(function (result) {
      if (result.ok && result.body.run_cmd) {
        copyText(result.body.run_cmd);
        stagedFlash[row.row_key] = "staged (cmd copied)";
      } else {
        stagedFlash[row.row_key] = result.body && result.body.error ? String(result.body.error) : "stage failed";
      }
      render();
    }).catch(function () {
      stagedFlash[row.row_key] = "stage failed";
      render();
    });
  }

  function failurePill(row) {
    var la = row.last_action;
    if (!la) return null;
    if (la.status === "failed") {
      var name = la.action || "action";
      var code = la.code == null || la.code === "" ? "" : " (exit " + la.code + ")";
      return el("span", { class: "chip crit", "data-pill": "failed" }, name + " failed" + code);
    }
    if (la.status === "refused_lane") {
      return el("span", { class: "chip crit", "data-pill": "refused" }, "refused: " + (la.error || "lane"));
    }
    return null;
  }

  function flashChip(row) {
    if (row.last_action && row.last_action.status === "failed") {
      delete stagedFlash[row.row_key];
      return null;
    }
    var text = stagedFlash[row.row_key];
    if (!text) return null;
    return el("span", { class: "chip", "data-flash": "1" }, text);
  }

  function needsActs(row) {
    var bits = [];
    if (row.action_url) bits.push(el("a", { class: "act", href: row.action_url }, row.action || ""));
    else if (row.action) bits.push(el("span", { class: "act" }, row.action));
    var lane = laneChip(row);
    if (lane) bits.push(lane);
    if (row.lane === "sofware" && row.wes && row.wes.copy_text) bits.push(wesChip(row));
    if (row.lane === "personal") {
      (Array.isArray(row.actions) ? row.actions : []).forEach(function (action) {
        bits.push(stageChip(row, action));
      });
    }
    var pill = failurePill(row);
    if (pill) bits.push(pill);
    var flash = flashChip(row);
    if (flash) bits.push(flash);
    return bits;
  }

  function renderNeeds(now) {
    var c = card("needs_you");
    var rows, shown, headRight, i, row, why;
    var countLabel = "Needs you";
    if (!hasData(c)) {
      needsEl.replaceChildren(
        el("div", { class: "head" },
          el("span", { class: "eyebrow" }, "Needs you"),
          el("span", { class: "note" }, (c && c.error) || "no data yet")
        ),
        emptyNote("no data yet")
      );
      return;
    }
    rows = Array.isArray(c.data) ? c.data : [];
    shown = rows.filter(function (r) { return matches(needHay(r), query); });
    countLabel = "Needs you · " + shown.length;
    headRight = "sorted by how long it has been waiting · quota last";
    if (staleBits(c).length) headRight = staleBits(c).join(" · ");
    needsEl.replaceChildren(
      el("div", { class: "head" },
        el("span", { class: "eyebrow" }, countLabel),
        el("span", { class: "note" }, headRight)
      ),
      el("ol", null, shown.map(function (row) {
        why = [row.detail, row.since ? formatAge(row.since, now) : ""].filter(Boolean).join(" · ");
        return el("li", null,
          el("span", { class: "id" },
            row.id || "",
            row.kind === "pr" ? el("span", { class: "chip" }, "gh") : null,
            row.kind === "linear" ? el("span", { class: "chip" }, "linear") : null,
            row.kind === "machine" ? el("span", { class: "chip" }, "fleet") : null
          ),
          el("span", null, row.title || "", el("br"), el("span", { class: "why" }, why)),
          el("span", { class: "acts" }, needsActs(row))
        );
      }))
    );
  }

  function renderWorktrees() {
    var c = card("worktrees");
    var rows, running, serverUp, idlePr, idle, prune, counts, headCount, bits, kids, open, btn;
    var head = el("div", { class: "head" }, el("h3", null, "Agents & worktrees"));
    if (!hasData(c)) {
      head.appendChild(el("span", { class: "count" }, (c && c.error) || "no data yet"));
      wtEl.replaceChildren(head, emptyNote("no data yet"));
      return;
    }
    rows = (c.data && c.data.rows) || [];
    counts = (c.data && c.data.counts) || {};
    bits = [];
    if (counts.sessions != null) bits.push(counts.sessions + " sessions");
    if (counts.worktrees != null) bits.push(counts.worktrees + " worktrees");
    if (counts.prunable != null) bits.push(counts.prunable + " prunable");
    headCount = bits.join(" · ");
    if (staleBits(c).length) headCount = (headCount ? headCount + " · " : "") + staleBits(c).join(" · ");
    head.appendChild(el("span", { class: "count" }, headCount || ""));

    running = rows.filter(isRunning);
    prune = rows.filter(function (r) { return !isRunning(r) && r.prunable; });
    serverUp = rows.filter(function (r) { return !isRunning(r) && !r.prunable && r.app_port != null; });
    idlePr = rows.filter(function (r) { return !isRunning(r) && !r.prunable && r.app_port == null && r.pr; });
    idle = rows.filter(function (r) { return !isRunning(r) && !r.prunable && r.app_port == null && !r.pr; });

    running = running.filter(function (r) { return matches(wtHay(r), query); });
    serverUp = serverUp.filter(function (r) { return matches(wtHay(r), query); });
    idlePr = idlePr.filter(function (r) { return matches(wtHay(r), query); });
    idle = idle.filter(function (r) { return matches(wtHay(r), query); });
    prune = prune.filter(function (r) { return matches(wtHay(r), query); });

    kids = [head];
    if (running.length) {
      kids.push(el("div", { class: "group" }, "Running"));
      running.forEach(function (r) { kids.push(runningRow(r)); });
    }
    if (serverUp.length) {
      kids.push(el("div", { class: "group" }, "Server up"));
      serverUp.forEach(function (r) { kids.push(idleRow(r)); });
    }
    if (idlePr.length) {
      kids.push(el("div", { class: "group" }, "Idle, has a PR"));
      idlePr.forEach(function (r) { kids.push(idleRow(r)); });
    }
    if (idle.length) {
      open = idleOpen || !!query;
      btn = el("button", { type: "button" }, open ? "collapse" : "expand");
      btn.addEventListener("click", function () { idleOpen = !idleOpen; render(); });
      kids.push(el("div", { class: "group" }, "Idle · " + idle.length + " ", btn));
      if (open) idle.forEach(function (r) { kids.push(idleRow(r)); });
    }
    if (prune.length) {
      kids.push(el("div", { class: "group" }, "Prunable · branch merged or PR closed, and no session in 14d"));
      prune.forEach(function (r) { kids.push(pruneRow(r)); });
    }
    wtEl.replaceChildren.apply(wtEl, kids);
  }

  function tabButton(id, label, selected) {
    var b = el("button", {
      type: "button",
      role: "tab",
      id: "tab-" + id,
      "aria-selected": selected ? "true" : "false",
      "aria-controls": "prs-" + id
    }, label);
    b.addEventListener("click", function () { prTab = id; render(); });
    return b;
  }

  function prChips(row) {
    var chips = [];
    if (row.draft) chips.push(el("span", { class: "chip" }, "draft"));
    else if (row.group === "blocked_on_me" || row.group === "blocked_on_them") chips.push(el("span", { class: "chip" }, "ready"));
    else chips.push(el("span", { class: "chip good" }, "ready"));
    if (row.details === "unknown") {
      chips.push(el("span", { class: "chip warn" }, "details unavailable"));
      return chips;
    }
    if (row.ci === "pass") chips.push(el("span", { class: "chip good" }, "ci"));
    else if (row.ci === "fail") chips.push(el("span", { class: "chip crit" }, "ci fail"));
    else if (row.ci === "pending") chips.push(el("span", { class: "chip warn" }, "ci pending"));
    if (row.threads_open > 0) chips.push(el("span", { class: "chip serious" }, row.threads_open + " threads"));
    if (row.repo && !homeRepo(row.repo)) {
      chips.push(el("span", { class: "chip" }, row.repo));
    }
    return chips;
  }

  function prRow(row, now, dim) {
    return el("a", { class: dim ? "row pr dim" : "row pr", href: row.url || "#" },
      el("span", { class: dim ? "id dim" : "id" }, "#" + row.number),
      el("span", { class: "title" }, row.title || ""),
      el("span", { class: "chips" }, prChips(row)),
      el("span", { class: "age" }, formatAge(row.since, now))
    );
  }

  function prGroup(label, rows, now) {
    var kids;
    if (!rows.length) return [];
    kids = [el("div", { class: "group" }, label)];
    rows.forEach(function (r) { kids.push(prRow(r, now)); });
    return kids;
  }

  function renderPrs(now) {
    var c = card("prs");
    var counts, mineN, revN, tabs, head, panel, mine, review, team, shown, stale, open, btn, panelKids;
    counts = (c && c.data && c.data.counts) || {};
    mineN = counts.mine != null ? counts.mine : 0;
    revN = counts.review_requested != null ? counts.review_requested : 0;
    tabs = el("div", { class: "tabs", role: "tablist", "aria-label": "PR lists" },
      tabButton("mine", "mine · " + mineN, prTab === "mine"),
      tabButton("review", "review requested · " + revN, prTab === "review")
    );
    head = el("div", { class: "head" }, el("h3", null, "Pull requests"), tabs);
    if (!hasData(c)) {
      prEl.replaceChildren(head, emptyNote((c && c.error) || "no data yet"));
      return;
    }
    mine = (c.data.mine || []).filter(function (r) { return matches(prHay(r), query); });
    review = (c.data.review_requested || []).filter(function (r) { return matches(prHay(r), query); });
    team = (c.data.review_requested_team || []).filter(function (r) { return matches(prHay(r), query); });
    if (prTab === "review") {
      panelKids = prGroup("Asked of me", review, now);
      if (team.length) {
        open = teamOpen || !!query;
        btn = el("button", { type: "button" }, open ? "collapse" : "expand");
        btn.addEventListener("click", function () { teamOpen = !teamOpen; render(); });
        panelKids.push(el("div", { class: "group" }, "via a team · " + team.length + " ", btn));
        if (open) team.forEach(function (r) { panelKids.push(prRow(r, now, true)); });
      }
      panel = el("div", { id: "prs-review", role: "tabpanel", "aria-labelledby": "tab-review" }, panelKids);
    } else {
      panel = el("div", { id: "prs-mine", role: "tabpanel", "aria-labelledby": "tab-mine" },
        prGroup("Blocked on me", mine.filter(function (r) { return r.group === "blocked_on_me"; }), now),
        prGroup("Blocked on them", mine.filter(function (r) { return r.group === "blocked_on_them"; }), now),
        prGroup("Ready, waiting on a reviewer", mine.filter(function (r) { return r.group === "ready"; }), now),
        prGroup("Details unavailable · GitHub returned no node for these", mine.filter(function (r) { return r.group === "unknown"; }), now)
      );
    }
    shown = [head, panel];
    stale = staleBits(c);
    if (stale.length) shown.splice(1, 0, el("div", { class: "note" }, stale.join(" · ")));
    prEl.replaceChildren.apply(prEl, shown);
  }

  function linChip(row) {
    var cls, wts;
    if (row.group === "waiting") {
      return el("span", { class: "chip warn" }, row.state || "");
    }
    if (row.group === "next_up") {
      return el("span", { class: "chip accent" }, "delegate");
    }
    if (row.agent) {
      cls = "chip";
      if (/\bwaiting\b/.test(row.agent)) cls += " warn";
      else if (/\bunconfirmed\b/.test(row.agent)) cls += " crit";
      else if (/\bworking\b/.test(row.agent)) cls += " good";
      return el("span", { class: cls }, row.agent);
    }
    wts = row.worktrees || [];
    if (wts.length === 1) return el("span", { class: "chip" }, wts[0]);
    if (wts.length > 1) return el("span", { class: "chip" }, wts.length + " worktrees");
    if (row.state) return el("span", { class: "chip" }, row.state);
    return null;
  }

  function linRow(row, now) {
    return el("a", { class: "row lin", href: row.url || "#" },
      el("span", { class: "id" }, row.id || ""),
      el("span", { class: "title" }, row.title || ""),
      el("span", { class: "chips" }, linChip(row)),
      el("span", { class: "age" }, formatAge(row.since, now))
    );
  }

  function mentionRow(row, now) {
    return el("a", { class: "row lin", href: row.comment_url || row.url || "#" },
      el("span", { class: "id" }, row.issue_id || ""),
      el("span", { class: "title" }, row.title || ""),
      el("span", { class: "chips" }, row.actor ? el("span", { class: "chip" }, row.actor) : null),
      el("span", { class: "age" }, formatAge(row.at, now))
    );
  }

  function linGroup(label, rows, now) {
    var kids;
    if (!rows.length) return [];
    kids = [el("div", { class: "group" }, label)];
    rows.forEach(function (r) { kids.push(linRow(r, now)); });
    return kids;
  }

  function renderLinear(now) {
    var c = card("linear");
    var counts, mineN, headCount, mine, mentions, waiting, progress, nextUp, other;
    var kids, stale, open, btn;
    counts = (c && c.data && c.data.counts) || {};
    mineN = counts.mine;
    headCount = mineN != null ? "mine · " + mineN : ((c && c.error) || "no data yet");
    stale = staleBits(c);
    if (stale.length) headCount = (headCount ? headCount + " · " : "") + stale.join(" · ");
    if (!hasData(c)) {
      linEl.replaceChildren(
        el("div", { class: "head" }, el("h3", null, "Linear"), el("span", { class: "count" }, headCount)),
        emptyNote((c && c.error) || "no data yet")
      );
      return;
    }
    mine = (c.data.mine || []).filter(function (r) { return matches(linHay(r), query); });
    mentions = (c.data.mentions || []).filter(function (r) { return matches(linHay(r), query); });
    waiting = mine.filter(function (r) { return r.group === "waiting"; });
    progress = mine.filter(function (r) { return r.group === "in_progress"; });
    nextUp = mine.filter(function (r) { return r.group === "next_up"; });
    other = mine.filter(function (r) { return r.group === "other"; });
    kids = [
      el("div", { class: "head" }, el("h3", null, "Linear"), el("span", { class: "count" }, headCount))
    ];
    if (mentions.length) {
      kids.push(el("div", { class: "group" }, "Needs a reply · " + mentions.length));
      mentions.forEach(function (r) { kids.push(mentionRow(r, now)); });
    }
    kids = kids.concat(linGroup("Waiting on a person", waiting, now));
    kids = kids.concat(linGroup("In progress", progress, now));
    kids = kids.concat(linGroup("Next up · " + nextUpLabel() + ", unassigned to an agent", nextUp, now));
    if (other.length) {
      open = otherOpen || !!query;
      btn = el("button", { type: "button" }, open ? "collapse" : "expand");
      btn.addEventListener("click", function () { otherOpen = !otherOpen; render(); });
      kids.push(el("div", { class: "group" }, "Other · " + other.length + " ", btn));
      if (open) other.forEach(function (r) { kids.push(linRow(r, now)); });
    }
    linEl.replaceChildren.apply(linEl, kids);
  }

  function paceGlyph(pace) {
    if (pace === "ahead") return "▲";
    if (pace === "under") return "▼";
    return "";
  }

  function meterClass(pct) {
    if (pct >= 80) return "crit";
    if (pct >= 50) return "warn";
    return "";
  }

  // Same rule as the status line: a time within 24h, a weekday within 7 days,
  // else a date.
  function monthDay(isoDay) {
    var months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
    var p = String(isoDay || "").split("-");
    if (p.length < 3 || !months[Number(p[1]) - 1]) return "";
    return months[Number(p[1]) - 1] + " " + Number(p[2]);
  }

  // Calendar day in Pacific time, YYYY-MM-DD. Claude's hand-kept term is that zone.
  function ptDay(iso) {
    var t = Date.parse(iso);
    if (isNaN(t)) return "";
    return new Intl.DateTimeFormat("en-CA", {
      timeZone: "America/Los_Angeles", year: "numeric", month: "2-digit", day: "2-digit"
    }).format(new Date(t));
  }

  // A pool reset that is the subscription's timed renewal is that one clock,
  // shown on the band header. A date-only term is a Pacific day, not an
  // instant, and never matches. Cursor Models, Other Models, and the Cursor
  // bill already share cursor_reset_ts, so this compares the two stamps the
  // seat already has.
  function sameTimedInstant(seat) {
    var resetT, termT;
    if (seat.renews_date_only) return false;
    if (!seat.resets_at || !seat.renews_at) return false;
    resetT = Date.parse(seat.resets_at);
    termT = Date.parse(seat.renews_at);
    return !isNaN(resetT) && !isNaN(termT) && resetT === termT;
  }

  // A distinct reset after a plan that will not renew stays on the row, with
  // a mark. A date-only term counts the reset's Pacific day on or after
  // renews_on. A timed term counts an instant strictly after the term.
  function resetAfterNonRenewingTerm(seat) {
    var resetT, termT, day;
    if (seat.renews !== false) return false;
    if (!seat.resets_at || !seat.renews_at) return false;
    if (seat.renews_date_only && seat.renews_on) {
      day = ptDay(seat.resets_at);
      return !!day && day >= seat.renews_on;
    }
    resetT = Date.parse(seat.resets_at);
    termT = Date.parse(seat.renews_at);
    return !isNaN(resetT) && !isNaN(termT) && resetT > termT;
  }

  function resetLabel(at, now) {
    var t = at ? Date.parse(at) : NaN;
    var d, h, m;
    if (isNaN(t) || t <= now) return "";
    d = new Date(t);
    if (t - now < 86400000) {
      h = d.getHours() % 12 || 12;
      m = d.getMinutes();
      return h + (m ? ":" + String(m).padStart(2, "0") : "") + (d.getHours() < 12 ? "am" : "pm");
    }
    if (t - now < 7 * 86400000) return new Intl.DateTimeFormat("en-US", { weekday: "short" }).format(d);
    return (d.getMonth() + 1) + "/" + d.getDate();
  }

  // Milliseconds until the paid-through mark. A date-only term is a Pacific
  // calendar day, so the value is whole days and 0 means that day itself.
  // A timed term is the instant minus now, and 0 means that instant.
  function termLeftMs(seat, now) {
    var day, start, end, t;
    if (seat.renews_date_only && seat.renews_on) {
      day = ptDay(new Date(now).toISOString());
      if (!day) return NaN;
      start = Date.parse(day + "T00:00:00Z");
      end = Date.parse(seat.renews_on + "T00:00:00Z");
      if (isNaN(start) || isNaN(end)) return NaN;
      return end - start;
    }
    t = seat.renews_at ? Date.parse(seat.renews_at) : NaN;
    return isNaN(t) ? NaN : t - now;
  }

  function termPast(seat, now) {
    var left = termLeftMs(seat, now);
    if (isNaN(left)) return false;
    return seat.renews_date_only ? left < 0 : left <= 0;
  }

  // The subscription behind the pool: when it renews, or when it ends if it
  // will not. renews is null when nobody knows, as with Claude's hand-kept date.
  function renewalPart(seat, now) {
    var t = seat.renews_at ? Date.parse(seat.renews_at) : NaN;
    var when, verb, title, past;
    if (isNaN(t) && !(seat.renews_date_only && seat.renews_on)) return null;
    if (isNaN(termLeftMs(seat, now))) return null;
    past = termPast(seat, now);
    if (past) {
      when = "";
      verb = seat.renews === false ? "sub ended" : "sub renewal due";
    } else {
      when = " " + (seat.renews_date_only && seat.renews_on ? monthDay(seat.renews_on) : resetLabel(seat.renews_at, now));
      verb = seat.renews === true ? "renews" : seat.renews === false ? "sub ends" : "term ends";
    }
    title = "Subscription paid through " +
      (seat.renews_date_only && seat.renews_on ? monthDay(seat.renews_on) + ", the whole Pacific day." : new Date(t).toLocaleString() + ".") + " " +
      (seat.renews === true ? "Set to renew." : seat.renews === false ? "Set to end; it will not renew." : "Renewal not known.") +
      (seat.renews_source === "by hand" ? " Date kept by hand in ~/.config/seat-usage/renewals.json; no endpoint returns it." : "");
    return el("span", { class: renewalWarns(seat, now) ? "caps" : "renew", title: title }, verb + when);
  }

  // A plan that was set not to renew and is past its paid-through date. Its
  // pool may still report numbers, but they no longer describe usable work.
  function subEnded(seat, now) {
    return seat.renews === false && termPast(seat, now);
  }

  // A plan that will not renew warns in its last week.
  function renewalWarns(seat, now) {
    var left = termLeftMs(seat, now);
    return seat.renews === false && !isNaN(left) && left >= 0 && left < 7 * 86400000;
  }

  // Share of the seat's window already elapsed, 0-100, or null.
  function elapsedPct(seat, now) {
    var t = seat.resets_at ? Date.parse(seat.resets_at) : NaN;
    var w = Number(seat.window_s);
    if (isNaN(t) || !(w > 0)) return null;
    return Math.max(0, Math.min(100, 100 - ((t - now) / 1000) * 100 / w));
  }

  // "HTTPError 401" out of seat-usage's failure text, or nothing.
  function readCode(why) {
    var m = /\b[A-Z]\w*Error(?: \d{3})?/.exec(why || "");
    return m ? ": " + m[0] : "";
  }

  function fiveHourTrack(five, weekly, now, nowPos) {
    var t = el("span", { class: "track five", title: "5h window" });
    var e = elapsedPct(five, now);
    var w = parseFloat(weekly.style.width) || 50;
    var pct = Math.max(0, Math.min(100, Number(five.percent)));
    var cls, fill;
    t.style.width = w + "%";
    t.style.left = e == null ? weekly.style.left : nowPos - w * e / 100 + "%";
    if (pct >= 100) cls = "crit";
    else if (e == null) cls = meterClass(pct);
    else cls = pct > e ? "over" : "";
    fill = el("i", cls ? { class: cls } : null);
    fill.style.width = pct + "%";
    if (cls === "over") fill.style.setProperty("--split", (e * 100 / pct) + "%");
    t.appendChild(fill);
    return t;
  }

  // Claude's 5h window rides on the weekly row as text. It turns red on the
  // status line's rule: used past the window's elapsed share, or full.
  function fiveHourPart(five, text, now) {
    var pct = Number(five.percent);
    var e = elapsedPct(five, now);
    var over = pct >= 100 || (e != null && pct > e);
    var title = e == null ? text : text + " used · " + Math.round(e) + "% of 5h window elapsed";
    return el("span", { class: over ? "hot" : null, title: title }, text);
  }

  // When the current rate would empty the pool before the reset: how soon,
  // and how early. Skipped in the first tenth of a window, where one large
  // job projects a cap that is not real.
  function capsLabel(pct, elapsed, windowS) {
    var used, rate, capIn, left;
    if (!(windowS > 0) || elapsed < 10 || pct >= 100 || pct <= elapsed) return null;
    used = windowS * elapsed / 100;
    left = windowS - used;
    rate = pct / used;
    capIn = (100 - pct) / rate;
    if (capIn >= left) return null;
    return { text: "caps " + roughSpan(left - capIn) + " early", title: "at this rate the pool empties in " + roughSpan(capIn) };
  }

  function roughSpan(secs) {
    return formatSpan(secs < 3600 ? secs : Math.round(secs / 3600) * 3600);
  }

  // The status line's pool for each seat, which sets its hue. Grok Bot bills
  // the Cursor seat, so it sits in Cursor's pool there too. A row the server
  // built from quartermaster's seat rows names its own vendor.
  function seatVendor(seat) {
    if (seat && typeof seat === "object") {
      if (seat.vendor) return String(seat.vendor);
      seat = seat.seat;
    }
    var id = String(seat || "");
    if (id.indexOf("claude") === 0) return "claude";
    if (id === "codex") return "codex";
    if (id.indexOf("cursor") === 0 || id === "grokbot") return "cursor";
    if (id === "supergrok") return "grok";
    if (id === "muse") return "muse";
    return "";
  }

  // Same seat-to-subscription map as quota_renewal in server.rb. Grok Bot is
  // on the Cursor bill. Muse has no renewal key and stays its own id. A row
  // built from the seat rows names its own subscription.
  function seatSubscription(seat) {
    if (seat && typeof seat === "object") {
      if (seat.subscription) return String(seat.subscription);
      seat = seat.seat;
    }
    var id = String(seat || "");
    if (id.indexOf("claude") === 0) return "claude";
    if (id.indexOf("cursor") === 0 || id === "grokbot") return "cursor";
    if (id === "supergrok") return "grok";
    return id;
  }

  function hbText(row) {
    var s = row.heartbeat_age_s;
    if (row.heartbeat === "unknown" || s == null || isNaN(Number(s))) return "hb —";
    s = Number(s);
    if (s < 60) return "hb " + s + "s";
    return "hb " + formatSpan(s);
  }

  // The Grok Bot link is not drawn here; it only feeds the needs-you rows.
  function machineRow(row) {
    var hbCls = "hb" + (row.heartbeat === "dead" ? " dead" : "");
    var attrs = { class: row.expected_always_on ? "machine" : "machine off" };
    if (row.note) attrs.title = row.note;
    return el("span", attrs,
      el("span", { class: "label" }, row.label || row.id || ""),
      el("span", { class: hbCls }, hbText(row)),
      row.expected_always_on ? null : el("span", { class: "chip" }, "not always-on")
    );
  }

  function renderFleet() {
    var c = card("machines");
    var head = el("span", { class: "head" }, el("span", { class: "eyebrow" }, "Machines"));
    var noteBits = staleBits(c);
    if (c && c.data && c.data.cache_present === false && !noteBits.length) noteBits.push("no fleet cache");
    if (noteBits.length) head.appendChild(el("span", { class: "note" }, noteBits.join(" · ")));
    if (!hasData(c)) {
      if (!noteBits.length) head.appendChild(el("span", { class: "note" }, "no data yet"));
      fleetEl.replaceChildren(head);
      return;
    }
    var rows = (c.data.machines || []).filter(function (row) {
      return matches([row.label, row.id, row.heartbeat, row.note].filter(Boolean).join(" "), query);
    });
    fleetEl.replaceChildren(head, el("div", { class: "machines" }, rows.map(function (row) {
      return machineRow(row);
    })));
  }

  // A pool that can take work now: a live reading under its cap, on a plan
  // that has not ended. Claude's rows also need the weekly and 5h limits.
  function seatUsable(seat, byId, now) {
    var weekly = byId.claude_weekly;
    if (!seat || seat.status !== "live" || subEnded(seat, now) || seat.exhausted) return false;
    if (!(Number(seat.percent) < 100)) return false;
    if (seatVendor(seat) === "claude" && seat !== weekly) return seatUsable(weekly, byId, now);
    if (seat.five_hour && !(Number(seat.five_hour.percent) < 100)) return false;
    return true;
  }

  function familyChip(name, seatId) {
    var cls = "chip fam" + (METERED[seatId] ? " metered" : "") + (BUILDER_ONLY[seatId] ? " builder" : "");
    var title = name + (METERED[seatId] ? ", metered" : "") + (BUILDER_ONLY[seatId] ? ", builder only" : "") +
      ". Hover to show its pools, click to pin.";
    var chip = el("button", { type: "button", class: cls, "data-family": name, "aria-pressed": "false", title: title }, name);
    chip.addEventListener("mouseenter", function () { famPreview = name; applyFamily(); });
    chip.addEventListener("focus", function () { famPreview = name; applyFamily(); });
    chip.addEventListener("mouseleave", function () { famPreview = null; applyFamily(); });
    chip.addEventListener("blur", function () { famPreview = null; applyFamily(); });
    chip.addEventListener("click", function () {
      famPinned = famPinned === name ? null : name;
      applyFamily();
    });
    return chip;
  }

  // On-demand spend is money past both Cursor bars and the Bot allowance, so it gets its own chip.
  // Amber on a capped pool, which is drawing on-demand now; red past the limit.
  function spendChip(od, capped) {
    var spent = Number(od.spent), limit = od.limit == null ? NaN : Number(od.limit);
    var text = "$" + spent.toFixed(2) + (isNaN(limit) ? " on-demand this cycle" :
      " of $" + limit.toFixed(0) + (spent > limit ? ", $" + (spent - limit).toFixed(2) + " over" : ""));
    var over = !isNaN(limit) && spent > limit;
    if (capped) text += ", this pool is capped";
    return el("span", { class: "spend" + (over ? " over" : capped ? " draw" : "") },
      el("button", { type: "button", class: "chip", "aria-label": "On-demand spend: " + text }, "$"),
      el("span", { class: "pop", role: "tooltip" }, "On-demand spend: " + text));
  }

  // Tints the rows that can serve the active family, dims the rest, and stars
  // the first usable one in the family's order. No re-render, so hover is cheap.
  function applyFamily() {
    var name = famPreview || famPinned;
    var fam = families().filter(function (f) { return f.name === name; })[0];
    var now = Date.now();
    var c = card("quota");
    var byId = {};
    var best = null;
    ((c && c.data && c.data.seats) || []).forEach(function (s) { byId[s.seat] = s; });
    if (fam) {
      best = fam.sources.filter(function (id) {
        // A plan with no Fable slice does not serve Fable from the weekly pool.
        if (name === "Fable" && id === "claude_weekly" && byId.claude_fable && byId.claude_fable.status === "absent") return false;
        return seatUsable(byId[id], byId, now);
      })[0] || null;
    }
    railEl.classList.toggle("fam-active", !!fam);
    Array.prototype.forEach.call(railEl.querySelectorAll(".seat"), function (row) {
      var id = row.getAttribute("data-seat");
      row.classList.toggle("fam-match", !!fam && fam.sources.indexOf(id) !== -1);
      row.querySelector(".star").textContent = fam && id === best ? "\u2605" : "";
    });
    Array.prototype.forEach.call(railEl.querySelectorAll(".chip.fam"), function (chip) {
      chip.setAttribute("aria-pressed", chip.getAttribute("data-family") === famPinned ? "true" : "false");
    });
    var key = railEl.querySelector(".rail-key .state");
    if (key) {
      key.textContent = !fam ? "" : " · " + name + (name === famPinned ? " pinned" : "") + " · " +
        (best ? "\u2605 " + (byId[best].label || best) : "no usable pool");
    }
  }

  function seatLabel(seat) {
    var chips = families().filter(function (f) { return f.sources.indexOf(seat.seat) !== -1; })
      .map(function (f) { return familyChip(f.name, seat.seat); });
    // On a capped pool, or on a Cursor row while spend this cycle is above zero:
    // the Bot resets weekly, but the spend stays on Cursor's bill.
    var od = seat.on_demand;
    var capped = seat.exhausted === true || Number(seat.percent) >= 100;
    if (od && od.spent != null && (capped || (seat.seat !== "grokbot" && Number(od.spent) > 0))) {
      chips.push(spendChip(od, capped));
    }
    return el("div", { class: "lab" },
      el("b", { title: seat.label || seat.seat || "" }, seat.label || seat.seat || ""),
      el("span", { class: "star", "aria-hidden": "true" }),
      chips);
  }

  // Display only. The name is the router's suggestion; the parenthesis is its
  // reason. Nothing here is a link or a button, and nothing launches a session.
  function hostSuggestionLabel(s) {
    var id = s && s.suggestion;
    var effort;
    if (!id) return "";
    if (id === "grokbot") return "Grok Bot";
    if (id === "opus") {
      effort = s.effort && s.effort !== "-" ? s.effort + " " : "";
      return "Opus " + effort + "on Max";
    }
    return String(s.family || id);
  }

  function leanClause(s) {
    var ids = s && s.lean;
    var names;
    if (!ids || !ids.length) return "";
    names = ids.map(function (id) {
      if (id === "cursor_models") return "Cursor Models";
      if (id === "grok") return "SuperGrok";
      return String(id);
    });
    if (names.length === 1) return "lean " + names[0];
    return "lean " + names[0] + ", then " + names.slice(1).join(", then ");
  }

  function hostSuggestionLine(s) {
    var label, reason, text, node;
    if (!s || typeof s !== "object") {
      text = "Next host: no cached route";
      return el("div", { class: "host-line", title: text }, text);
    }
    label = hostSuggestionLabel(s);
    reason = s.reason ? String(s.reason) : "";
    if (!label && s.mode === "ask") {
      text = "Next host: ask" + (reason ? " (" + reason + ")" : "");
      if (leanClause(s)) text += " · " + leanClause(s);
    } else if (label) {
      text = "Next host: " + label + (reason ? " (" + reason + ")" : "");
    } else {
      text = "Next host:" + (reason ? " " + reason : "");
    }
    node = el("div", { class: "host-line", title: text }, text);
    if (hostWhy(s)) node.appendChild(el("div", { class: "why" }, hostWhy(s)));
    return node;
  }

  // One clause per host the router passed over, then what the lean means.
  // Uses only the route's own fields; seat-usage still owns the rule.
  function hostWhy(s) {
    var names = { grokbot: "Grok Bot", opus: "Opus on Max" };
    var windows = { grokbot: "its weekly allowance", claude_week: "the Max weekly pool", claude_5h: "the Max 5h window" };
    var parts = (s.hosts || []).map(function (h) {
      var name = names[h.id] || h.id;
      var win = windows[h.binding] || h.binding || "its pool";
      var used = h.used_pct == null ? "" : " at " + Math.round(h.used_pct) + "%";
      if (h.state === "capped") return name + ": " + win + " is used up" + used + ".";
      if (h.state === "ahead") return name + ": " + win + " is" + used + ", ahead of the time elapsed, so it may run out before it resets.";
      if (h.state === "unknown") return name + ": no reading.";
      return "";
    }).filter(Boolean);
    if (!parts.length) return "";
    if (s.mode === "ask" && !hostSuggestionLabel(s)) {
      parts.push("No host is clear, so the router leaves the choice to you.");
      if (s.lean && s.lean.length) {
        parts.push("If you start one anyway, draw Grok from " + leanClause(s).replace(/^lean /, "") + " first.");
      }
    }
    return parts.join(" ");
  }

  // Grok Bot sits on the Cursor bill, so the plan name comes from another
  // seat in the subscription when there is one.
  function subscriptionCarrier(group) {
    var i;
    for (i = 0; i < group.length; i++) {
      if (group[i].seat !== "grokbot") return group[i];
    }
    return group[0];
  }

  // The pool is the label's tail ("Cursor Models"). Codex's tier lives in
  // plan, not in that tail. Claude and Cursor already put the display plan
  // on the front of the label.
  function poolName(seat) {
    var label = String(seat.label || seat.seat || "");
    var cut = label.indexOf(" · ");
    return cut === -1 ? label : label.slice(cut + 3);
  }

  function subscriptionPlan(group) {
    var seat = subscriptionCarrier(group);
    var head;
    if (seat.seat === "codex") return seat.plan ? "Codex " + seat.plan : "Codex";
    head = String(seat.label || "").split(" · ")[0];
    return head || String(seat.seat || "");
  }

  function poolsResetThen(names) {
    if (!names.length) return "";
    if (names.length === 1) return names[0] + " resets then";
    if (names.length === 2) return names[0] + " and " + names[1] + " reset then";
    return names.slice(0, -1).join(", ") + ", and " + names[names.length - 1] + " reset then";
  }

  // Line 1 is the plan plus today's renewal words, title, and warning class.
  // Line 2 names only the pools whose reset is that timed instant.
  function bandHeader(group, now) {
    var carrier = subscriptionCarrier(group);
    var part = renewalPart(carrier, now);
    var names = [];
    var line, vendor;
    if (!part) return null;
    part.textContent = subscriptionPlan(group) + " · " + part.textContent;
    group.forEach(function (seat) {
      var name;
      if (!sameTimedInstant(seat)) return;
      name = poolName(seat);
      if (name) names.push(name);
    });
    line = poolsResetThen(names);
    vendor = seatVendor(carrier);
    return el("div", {
      class: "band-hdr" + (vendor ? " " + vendor : ""),
      title: part.getAttribute("title")
    }, part, line ? el("span", { class: "sub" }, line) : null);
  }

  // Header index is the first seat of each subscription run. A run with no
  // renewal (Muse) gets none.
  function bandHeaders(list, now) {
    var headers = [];
    var start = 0;
    var sub, end, header;
    while (start < list.length) {
      sub = seatSubscription(list[start]);
      end = start + 1;
      while (end < list.length && seatSubscription(list[end]) === sub) end++;
      header = bandHeader(list.slice(start, end), now);
      if (header) headers[start] = header;
      start = end;
    }
    return headers;
  }

  // A pool that moved in the last 30 minutes is burn-soft; one that also rose
  // at least one pace over two hours is burn-strong. The server decides that
  // from seat-usage's history. The row only keeps a static outline. The dot
  // beside the percentage shows on a live seat that is burning, and its colour
  // is only burn_pph: green below 5 pts/hr, yellow from 5 up to 15, red at 15
  // and above. Every row that shows a percent reserves the dot's box. An
  // inactive percent row leaves that box empty so the column lines up. A row
  // with no percent does not reserve it.
  var BURN_TITLE = { soft: "burning in the last 30 min", strong: "burning above pace in the last 30 min" };
  function burnClass(seat, live) {
    return live && BURN_TITLE[seat.burn] ? " burn-" + seat.burn : "";
  }
  function burnActive(seat, live) {
    return !!(live && (seat.burn === "soft" || seat.burn === "strong"));
  }
  // Colour is burn_pph only. Pace, caps, and the percent do not enter.
  // A burning row with no rate is green.
  function dotColor(seat) {
    var n = seat && seat.burn_pph;
    if (n == null || n === "" || isNaN(Number(n))) return "green";
    n = Number(n);
    if (n >= DOT_RED_PPH) return "red";
    if (n >= DOT_YELLOW_PPH) return "yellow";
    return "green";
  }
  function dotTitle(seat) {
    var n = seat && seat.burn_pph;
    if (n == null || n === "" || isNaN(Number(n))) return "in use";
    return "in use · " + Number(n).toFixed(1) + " pts/hr";
  }
  function usageDot(seat) {
    var color = dotColor(seat);
    var node = el("span", {
      class: "dot dot-" + color,
      "data-dot": color,
      title: dotTitle(seat),
      "aria-hidden": "true"
    });
    node.style.animationDelay = "-" + (Date.now() % DOT_PHASE_MS) + "ms";
    return node;
  }
  // Same box as the coloured dot, including its margin. Hidden, so it adds no
  // words to the detail text or tooltip, and it does not animate.
  function usageSlot() {
    return el("span", { class: "dot dot-none", "aria-hidden": "true" });
  }
  function showsPercent(parts) {
    if (!parts.length) return false;
    var first = parts[0];
    var text = typeof first === "string" ? first : (first && first.textContent) || "";
    return String(text).indexOf("%") !== -1;
  }

  // One line per local tool with a working session: label and pool, no rates.
  function driversBlock(list) {
    if (!Array.isArray(list) || !list.length) return null;
    return el("div", { class: "drivers" }, el("div", { class: "eyebrow" }, "Running now"),
      list.map(function (d) {
        var n = Number(d.sessions) > 1 ? " (" + Number(d.sessions) + ")" : "";
        var text = String(d.label || "") + n + " · " + String(d.pool || "");
        return el("div", { class: "drv", title: text }, text);
      }));
  }

  function renderRail(now) {
    var c = card("quota");
    var seats;
    if (c && c.data && Array.isArray(c.data.seats) && c.data.seats.length) {
      seats = c.data.seats;
    } else {
      seats = SEATS.map(function (s) {
        return { seat: s.seat, label: s.label, status: "unknown", percent: null, text: "unknown", pace: "", note: s.note, verified_at: null };
      });
    }
    // Ended plans sink to the bottom, otherwise in the status line's order.
    // A subscription's seats share one renewal, so they sink together and
    // the header stays on that band.
    seats = seats.filter(function (s) { return !subEnded(s, now); })
      .concat(seats.filter(function (s) { return subEnded(s, now); }));
    // One time scale for every row: a track's width is its window's length,
    // and the "now" line sits where the longest past and the longest future
    // just fit, so a reset's position is its real date.
    var maxPast = 0, maxFuture = 0;
    seats.forEach(function (seat) {
      var e = seat.status === "live" && !subEnded(seat, now) ? elapsedPct(seat, now) : null;
      var w = Number(seat.window_s);
      if (e == null) return;
      maxPast = Math.max(maxPast, w * e / 100);
      maxFuture = Math.max(maxFuture, w * (100 - e) / 100);
    });
    var span = maxPast + maxFuture;
    var nowPos = span > 0 ? maxPast * 100 / span : 50;
    var headerBefore = bandHeaders(seats, now);
    var prevVendor = null;
    var rows = [];
    seats.forEach(function (seat, i) {
      var live = seat.status === "live";
      var absent = seat.status === "absent";
      var vendor = seatVendor(seat);
      var nextVendor = i + 1 < seats.length ? seatVendor(seats[i + 1]) : null;
      var ownHeader = headerBefore[i];
      if (ownHeader) rows.push(ownHeader);
      var rowCls = ["seat", vendor, absent ? "absent" : "", vendor !== prevVendor && !ownHeader ? "vendor-start" : "", vendor !== nextVendor ? "vendor-end" : ""].filter(Boolean).join(" ");
      prevVendor = vendor;
      var bar, track, fill, pct, cls, parts, g, verified, reset, elapsed, caps, detail, ageMs, renewal, dot;
      // An ended plan gets a full grey bar and no usage, pace, or reset.
      if (subEnded(seat, now)) {
        track = el("span", { class: "track ended" });
        track.style.left = "0";
        track.style.width = "100%";
        renewal = renewalPart(seat, now);
        renewal.className = "renew";
        // After Pro lapses, ChatGPT drops to free, which runs neither Astra
        // nor Sol (tested 2026-10-08), so its bucket stays grey too.
        if (seat.seat === "codex" && seat.plan === "free") renewal.textContent = "Pro ended · free plan has no Astra or Sol";
        detail = el("span", { class: "v", title: renewal.title }, renewal);
        rows.push(el("div", { class: rowCls + " ended", "data-seat": seat.seat }, seatLabel(seat), el("div", { class: "meter" }, track), detail));
        return;
      }
      // The server's text also feeds the needs-you list, which has no meter.
      // Here the tick and the arrow already say the pace, so drop the words.
      parts = live ? String(seat.text || "").split(" · ").filter(function (p) {
        return p && !/^(on|ahead of|under) pace$/.test(p);
      }) : absent ? [seat.text || "not on this plan"] : ["unknown"];
      if (live && seat.five_hour) {
        parts = parts.map(function (p) { return /^5h \d/.test(p) ? fiveHourPart(seat.five_hour, p, now) : p; });
      }
      if (live) {
        g = paceGlyph(seat.pace);
        if (g && parts.length && parts[0].indexOf("%") !== -1) parts[0] = parts[0].replace("%", "%" + g);
        reset = resetLabel(seat.resets_at, now);
        if (reset && !sameTimedInstant(seat)) {
          parts.push(resetAfterNonRenewingTerm(seat) ? "pool reset " + reset + " (after term)" : "resets " + reset);
        }
      } else if (seat.note && !absent) {
        parts.push(seat.note);
      }
      // A failed read keeps the old numbers, so say so up front in red.
      if (seat.read_failed) parts.splice(live ? 1 : 0, 0, el("span", { class: "caps", title: "seat-usage could not read this seat; the numbers are from an older read" + (seat.read_error ? " (" + seat.read_error + ")" : "") }, "read failed" + readCode(seat.read_error)));
      // Every seat comes from one cache read, so its age only earns a place
      // once the background refresh has fallen behind.
      if (seat.verified_at) {
        ageMs = now - Date.parse(seat.verified_at);
        verified = formatFresh(seat.verified_at, now) || formatAge(seat.verified_at, now);
        if (verified && !live && !absent) parts.push("verified " + verified);
        else if (verified && ageMs > 15 * 60000) parts.push("stale " + verified);
      }
      // Each track is half the meter wide and slides so its pace tick sits on
      // the meter's centre line, which every row shares. Left of the line is
      // the window so far, right of it the window still to come, and the
      // track's right end is the cap. A seat with no known window centres.
      bar = el("div", { class: "meter" });
      track = el("span", { class: absent ? "track absent" : "track" });
      elapsed = live ? elapsedPct(seat, now) : null;
      if (absent) {
        track.style.left = "0";
        track.style.width = "100%";
      } else if (elapsed == null || !(span > 0)) {
        track.style.left = "25%";
      } else {
        track.style.width = Number(seat.window_s) * 100 / span + "%";
        track.style.left = nowPos - Number(seat.window_s) * elapsed / span + "%";
      }
      bar.appendChild(track);
      if (live && seat.percent != null && !isNaN(Number(seat.percent))) {
        pct = Math.max(0, Math.min(100, Number(seat.percent)));
        // Same rule as the status line: with a known window, the fill past
        // the pace tick is red, and a full pool is red throughout.
        if (pct >= 100) cls = "crit";
        else if (elapsed == null) cls = meterClass(pct);
        else cls = pct > elapsed ? "over" : "";
        fill = el("i", cls ? { class: cls } : null);
        fill.style.width = pct + "%";
        if (cls === "over") fill.style.setProperty("--split", (elapsed * 100 / pct) + "%");
        track.appendChild(fill);
      }
      // A seat with a 5h window gets a second track under the weekly one.
      // A 5h window on the shared time scale would be a sliver, so it takes
      // the weekly track's width and its own pace tick sits on the now line.
      if (live && seat.five_hour && seat.five_hour.percent != null && !isNaN(Number(seat.five_hour.percent))) {
        bar.className = "meter two";
        bar.appendChild(fiveHourTrack(seat.five_hour, track, now, nowPos));
      }
      if (elapsed != null) {
        bar.appendChild(el("s", { title: "now · " + Math.round(elapsed) + "% of window elapsed" }));
        bar.lastChild.style.left = nowPos + "%";
      }
      caps = pct != null && elapsed != null ? capsLabel(pct, elapsed, Number(seat.window_s)) : null;
      // The caps warning goes right after the percentage, so a narrow row
      // cuts the reset day, not the warning. The dot sits in front of that
      // percentage on every live row the server marked soft or strong. Any
      // other row that shows a percent keeps an empty slot in that same place.
      // Absent, unknown, and ended rows have no percent and no slot.
      if (caps) parts.splice(1, 0, el("span", { class: "caps", title: caps.title }, caps.text));
      detail = el("span", { class: "v" });
      dot = burnActive(seat, live) ? usageDot(seat) : (showsPercent(parts) ? usageSlot() : null);
      parts.forEach(function (p, i) {
        if (i === 0 && dot) detail.append(dot);
        if (i) detail.append(" · ");
        detail.append(p);
      });
      if (!parts.length && dot) detail.append(dot);
      detail.title = absent && seat.note ? seat.note + " " + detail.textContent : detail.textContent;
      // The row has no burn text. The dot's title and this tooltip carry it.
      if (live && BURN_TITLE[seat.burn]) detail.title += " · " + BURN_TITLE[seat.burn];
      rows.push(el("div", { class: rowCls + burnClass(seat, live), "data-seat": seat.seat, "data-burn": live && BURN_TITLE[seat.burn] ? seat.burn : null }, seatLabel(seat), bar, detail));
    });
    railEl.replaceChildren.apply(railEl, [hostSuggestionLine(c && c.data && c.data.host_suggestion)].concat(rows));
    var drivers = driversBlock(c && c.data && c.data.drivers);
    if (drivers) railEl.appendChild(drivers);
    railEl.appendChild(el("div", { class: "rail-key" },
      "dashed = metered · dotted = builder only · \u2605 first usable pool for the family",
      el("span", { class: "state" })));
    applyFamily();
  }

  // Repos named in the dotfiles profile are the home set, so a PR chip only
  // appears for a repo outside that set.
  function nextUpLabel() {
    var p = payload && payload.profile;
    return (p && p.next_up_label) ? String(p.next_up_label) : "labelled";
  }

  function homeRepo(name) {
    var repos = payload && payload.profile && payload.profile.repos;
    return !!(name && repos && repos.indexOf(name) !== -1);
  }

  function applyChrome() {
    var p = payload && payload.profile;
    var brand = document.getElementById("brand");
    var name, who, mark;
    if (!brand) return;
    name = p && p.brand ? String(p.brand) : "ops";
    who = p && p.viewer ? String(p.viewer) : "";
    brand.replaceChildren(document.createTextNode(name));
    if (who) {
      mark = el("span", { class: "mono", style: "color:var(--muted);font-weight:400" }, "· " + who);
      brand.appendChild(document.createTextNode(" "));
      brand.appendChild(mark);
    }
    if (qEl && p && p.search_placeholder) qEl.placeholder = String(p.search_placeholder);
  }

  function render() {
    var now = Date.now();
    applyChrome();
    renderMeta(now);
    renderNeeds(now);
    renderWorktrees();
    renderPrs(now);
    renderLinear(now);
    renderFleet();
    renderRail(now);
  }

  function load() {
    var n = ++loadSeq;
    fetch(CARDS_URL, { cache: "no-store" }).then(function (res) {
      if (!res.ok) throw new Error("HTTP " + res.status);
      return res.json();
    }).then(function (data) {
      if (n !== loadSeq) return;
      payload = data;
      fetchError = null;
      render();
    }).catch(function (err) {
      if (n !== loadSeq) return;
      fetchError = err && err.message ? err.message : "fetch failed";
      render();
    });
  }

  function armPoll() {
    if (pollTimer !== null) {
      clearInterval(pollTimer);
      pollTimer = null;
    }
    if (document.visibilityState === "visible") {
      pollTimer = setInterval(load, POLL_MS);
    }
  }

  qEl.addEventListener("input", function () {
    query = qEl.value;
    render();
  });

  document.addEventListener("keydown", function (e) {
    var tag = (e.target && e.target.tagName) || "";
    var typing = tag === "INPUT" || tag === "TEXTAREA";
    if (e.key === "/" && !typing && !e.ctrlKey && !e.metaKey && !e.altKey) {
      e.preventDefault();
      qEl.focus();
      qEl.select();
    } else if (e.key === "Escape") {
      if (famPinned) {
        famPinned = null;
        applyFamily();
      }
      if (qEl.value) {
        qEl.value = "";
        query = "";
        render();
      }
      qEl.blur();
    }
  });

  document.addEventListener("visibilitychange", function () {
    load();
    armPoll();
  });

  render();
  load();
  armPoll();
})();
