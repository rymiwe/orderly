# Build me a personal New Tab dashboard

Build a browser New Tab page that answers one question when I open a tab:
**what is waiting on me?** Agent sessions that are stuck or waiting for a
reply, pull requests blocked on me, Linear tickets in states I act on, plus my
worktrees with their app ports and a list of worktrees I can prune. Nothing
else. No bookmarks, no clock, no quotes.

A working version exists at https://github.com/rymiwe/orderly (private, ask
Ryan for access). Read its README and `server.rb` first. You may start from
it and adapt, or build fresh to the same design. Either way, the decisions
below are settled. Do not redesign them; adapt them to my machine.

## Architecture, settled

1. **Two parts.** A single-file local server that owns every credential and
   CLI call, and an unpacked Chrome extension (manifest, `newtab.html`,
   `newtab.js`) that only fetches JSON from it. Nothing sensitive ever lives
   in the extension. Chrome requires the new-tab page to be bundled in the
   extension; it cannot point at a URL, so the page fetches the server.
2. **Server:** one file, standard library only, no database. Ryan's is Ruby
   with webrick. Use whatever runtime I already have. Bind
   `127.0.0.1:<port>`; pick a port nothing on my machine uses.
3. **CORS:** answer only `Origin: chrome-extension://<my extension id>`.
   The id comes from an env file the server reads at boot, set once after I
   load the extension. A dev flag allows `Origin: null` so the page can be
   tested from `file://` before loading it into Chrome.
4. **One endpoint,** `GET /cards`, returning every card as
   `{data, fetched_at, error}`. Each card keeps its last good result in
   memory and on disk. A failed fetch returns the last good data with its
   old `fetched_at` and the error, never an empty card. Before the first
   success a card says "no data yet".
5. **Refresh:** local sources every 5s, remote sources (GitHub, Linear,
   quota) every 2 minutes, on server-side timers. The page polls `/cards`
   every 5s only while visible.
6. **Layout:** a search box on top (`/` focuses it, filters rows by ticket
   id, PR number, port, branch). A "needs you" strip first, sorted by how
   long each item has waited, quota rows last. Three columns: agents and
   worktrees, pull requests (tabs: mine, review requested), Linear. Seat
   meters in a rail at the bottom. Dark first, light via
   `prefers-color-scheme`.
7. **Agent state per worktree,** aggregated over every session in that
   directory, not just the newest. States: working, waiting, unconfirmed,
   idle. A live process is only ever working or waiting.
8. **"Unconfirmed"** means the process is gone and the session's own log does
   not end with a completed turn. Never call it "died". Exit 0 is not a
   completion badge.
9. **Prunable worktree, one rule:** its branch is merged into the main
   branch or its PR is closed, and no agent session has touched it in 14
   days. The row shows the `git worktree remove` command. Nothing runs
   without a click, and the first version does not need the click at all.
10. **Quota meters only where a live read exists.** Otherwise the meter says
    "unknown" with the time it was last checked. Never estimate a percentage.
11. **Copy** stays in product vocabulary. This page is mine alone, but keep
    the habit.

## Build in phases, verify each with real data, commit after each

1. **Local cards:** worktrees from `git worktree list --porcelain` for each
   repo root, merged check with `git branch --merged`, PR per branch from
   one `gh pr list --state all` call per repo, app port by matching listening
   sockets to the process's working directory (Linux: `/proc/<pid>/cwd`;
   macOS: `lsof`), never a database port. Agent sessions from each CLI's own
   session files (see below). Verify with `curl` and name two worktrees whose
   rows must look right.
2. **The page,** tested from `file://` with a headless Chrome screenshot
   before anything touches my browser. Then I load it unpacked at
   `chrome://extensions` in the profile I choose and hand you the id.
3. **GitHub:** `gh search prs --author=@me --state=open` and
   `--review-requested=@me`, then one aliased GraphQL query for CI state,
   unresolved review threads with their last commenter, review decision,
   and review requests. Group mine as blocked on me (CI failed, a thread
   whose last comment is not mine, changes requested), blocked on them, or
   ready. **`--review-requested=@me` includes requests sent to a team and
   bots' PRs;** keep only requests naming me directly for the main list,
   show team requests in a collapsed group, and drop `dependabot`.
   Needs-you rows: CI failed, threads awaiting me, changes requested, a
   direct review request. Cap PR rows in the strip at 14 days old.
4. **Linear:** GraphQL at `https://api.linear.app/graphql`, header
   `Authorization: <key>` with no "Bearer". One fixed query for my assigned
   issues with state, team, labels, and the newest comment's author. Groups:
   waiting on a person (state names from a local profile), in progress, next up
   (a label from that profile, no worktree yet), other collapsed. Needs-you row when
   a waiting ticket's newest comment is not mine. The key never goes in the
   repo, the cache, or a log; read it at boot from wherever I keep secrets
   (Ryan reads his from 1Password through the `op` CLI).
5. **Quota meters** from whatever live read exists for my seats. Ryan's
   status line already had a script that polls his vendors and writes a
   cache file; the dashboard reads that cache and asks the script to refresh
   it when stale, behind the same lock. If I have nothing like that, every
   meter reads "unknown" until one exists.
6. **Smoke pings:** for every worktree with an app port, `GET` the paths listed
   for that repo in the local profile, 2s timeout, green on 200 or 302.
7. **A user-level service** (`systemd --user` on Linux, `launchd` on macOS)
   that runs the server at login, with my user bin directories on its PATH,
   because the service PATH will not have them.

## Where each CLI keeps its sessions (adapt to the ones I use)

- **Claude Code:** `~/.claude/sessions/<pid>.json` per live session with
  `cwd`, `status`, `sessionId`. Drop a file whose pid is not alive.
  Transcript at `~/.claude/projects/<cwd with / replaced by ->/<sessionId>.jsonl`;
  read only its tail, some are hundreds of MB.
- **Grok Build:** `~/.grok/sessions/<cwd url-encoded>/<uuid>/events.jsonl`;
  the last line's `turn_ended` with `outcome: completed` is the only
  completion signal. Skip sessions older than 7 days, and skip any directory
  the dashboard itself runs probes from.
- **Codex:** `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`, cwd in the first
  lines. A count per day is enough to start.
- **Cursor:** `cursor-agent ls` hangs without a TTY. Skip it unless it works
  under `timeout`.

## Gotchas Ryan hit

- Verify which listening ports are app servers. Vite and stray node
  processes look like app servers by port alone; match by working directory
  and process name.
- A worktree list will include detached review trees under `/tmp`. They are
  real worktrees and often prunable.
- Only one extension can own the new tab; loading this replaces whatever
  has it now, silently, in that profile only.
- An extension id is derived from the unpacked folder's path, so the same
  folder gives the same id in every profile.
- Inline `<script>` in the new-tab page needs a CSP hash that changes on
  every edit. Put the script in its own file instead.
- If the dashboard probes a vendor with a real model call, that probe
  spends quota and leaves sessions behind. Read a cache or a log instead.

## Rules for you, the agent

- Never run anything that mutates a repo, a PR, a ticket, or my browser.
  Read-only everywhere except the dashboard's own directory.
- Never print, log, cache, or commit a token or key. Report a key's length
  at most.
- Verify with real output from my machine and paste it. Your own "PASS" is
  not evidence.
- If a step is blocked, stop and say why. Do not substitute a
  plausible-looking artifact.
- Ask me before loading the extension, before any step that needs a key, and
  before starting the service.
