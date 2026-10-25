# Orderly

The orderly room: the board where the day's business is posted. Not the hospital kind.

Local JSON server plus an unpacked Chrome new-tab page. The server owns every CLI call and credential. The page only fetches JSON from `127.0.0.1:5180`. Ruby 3.4 stdlib plus the installed `webrick` gem.

## Run

```bash
OPS_TAB_DEV=1 ruby server.rb
```

`OPS_TAB_DEV=1` allows `file://` (`Origin: null`) so the page can be opened from disk while developing. Stop with Ctrl-C. Nothing else should listen on 5180.

## Env vars

Loaded from the process environment, then (without overriding) from `~/.config/ops-tab/env` as `KEY=VALUE` lines at boot.

| Variable | Meaning |
|---|---|
| `OPS_TAB_EXTENSION_ID` | Chrome extension id. Requests with `Origin: chrome-extension://<id>` get `Access-Control-Allow-Origin`. |
| `OPS_TAB_DEV` | Set to `1` to also allow `Origin: null` (file://) and `http://127.0.0.1:*` on `GET /cards` and `GET /health`. `POST /actions/stage` still rejects a missing Origin and `Origin: null`. |
| `OPS_TAB_PORT` | Listen port. Default `5180`. |

Workplace and machine facts are `~/.config/ops-tab/profile.json`, kept in dotfiles, not in this repo. A missing file leaves the repo list, the brand, and the Linear key reference empty. The page reads `profile` on `/cards` for the brand, the name beside it, and the search placeholder.

```json
{
  "brand": "ops",
  "viewer": "me",
  "github_org": "my-org",
  "search_placeholder": "press / to focus",
  "linear_op_ref": "<1Password secret reference>",
  "op_bin": "op",
  "waiting_states": ["review"],
  "next_up_label": "ready",
  "fleet_expected": [{ "id": "laptop", "label": "Laptop" }],
  "repos": [
    { "name": "app", "root": "~/code/app", "db_port": 5432, "pings": ["/login", "/health"] }
  ],
  "personal_repos": [],
  "sofware_repos": [],
  "personal_linear_teams": [],
  "sofware_linear_teams": [],
  "personal_worktree_roots": [],
  "sofware_worktree_roots": []
}
```

`repos[].root` may start with `~`. `pings` defaults to `/login` when omitted. `fleet_expected` hosts are the ones treated as always on. `waiting_states` are the Linear state names that count as waiting, matched case-insensitively.

Lane lists are exact strings. `personal_repos` and `sofware_repos` match a PR's `owner/repo` or its bare repo name, whichever is written. Linear lists match a team key (`RYA`) or the team prefix of an identifier (`RYA-123`). Worktree lists are absolute directory prefixes for agent sessions. A row that matches neither list, or both, is `unknown`. `repos` and `github_org` are not lanes.

Requests with no `Origin` header (curl) are allowed on `GET /cards` and `GET /health`. Any other origin gets `403` and no CORS headers. `POST /actions/stage` does not allow a missing Origin; see Needs-you actions below.

Every request also has its `Host` header checked. Only `127.0.0.1`, `localhost` and `::1` pass, with no port or the listen port. Anything else gets `403` and `{"error":"forbidden host"}`. This is what stops a DNS-rebinding page reaching the server, because such a page sends no `Origin`.

## Endpoints

`GET /health` → `{ "ok": true }`

`GET /cards` →

```json
{
  "server_time": "<ISO8601>",
  "cards": {
    "worktrees": { "data": {}, "fetched_at": "<ISO8601>|null", "error": "<string>|null" },
    "agents":    { "data": {}, "fetched_at": "<ISO8601>|null", "error": "<string>|null" },
    "needs_you": { "data": [], "fetched_at": "<ISO8601>|null", "error": "<string>|null" },
    "prs":       { "data": {}, "fetched_at": "<ISO8601>|null", "error": "<string>|null" },
    "linear":    { "data": {}, "fetched_at": "<ISO8601>|null", "error": "<string>|null" },
    "quota":     { "data": {}, "fetched_at": "<ISO8601>|null", "error": "<string>|null" },
    "machines":  { "data": {}, "fetched_at": "<ISO8601>|null", "error": "<string>|null" }
  }
}
```

The server stores what each source last returned, never anything derived from another source. `/cards` composes the cards from those sources on every request: the PR and prune columns on a worktree row, a Linear issue's worktrees, agent and group, and the whole `needs_you` list are joins computed on the way out. A source therefore cannot carry a stale join, and no timer has to go back and correct one.

Each source keeps its last good data in memory and in `~/.local/state/ops-tab/cache.json`. A failed refresh keeps that data and its old `fetched_at`, and sets the card's `error`. Before the first success, `data` is `null` and `error` is `"no data yet"`. `/cards` never waits on a refresh.

`needs_you` is a projection of the local, `prs`, `linear`, `quota` and `machines` sources. Its `fetched_at` is the oldest of them and its `error` is theirs, so it never reads as current while the rows behind it are stale.

## Needs-you actions

`GET /cards` includes `action_token`, a per-boot hex string. It is a local request capability for the extension, not a vendor key. Personal rows also carry `lane`, `row_key`, and `actions` (`council`, `loop`, `draft`, `resume` — only the ones that fit that kind). SOFware rows carry a `wes` handoff string and no BLD command. Unknown rows carry `lane: "unknown"`. Quota and machine rows gain no actions.

`POST /actions/stage` with `{"row_key","action"}` writes `~/.local/state/ops-tab/staged/<slug>.json` and `.md` from the cached row only. It does not call `gh`, `op`, Linear, or a model. The response is `{ok, staged_path, run_cmd}`. The page copies `run_cmd` and does not run it. The command prints the brief; a non-zero exit overwrites `<slug>.status.json`. The next `GET /cards` shows that as a failure pill when the status `since` is still the row's `since`. A newer failure replaces the file. A row whose `since` changed does not keep the old pill. Staging again deletes the status file.

The route requires `Host` pinning, `Content-Type: application/json`, `Origin: chrome-extension://<OPS_TAB_EXTENSION_ID>`, and `X-Orderly-Token`. A missing Origin, `Origin: null`, and any other Origin are rejected even when `OPS_TAB_DEV=1`. `GET /actions/stage` returns 405 and writes nothing. A SOFware or unknown row returns 422, writes no packet, and appends a refusal to `~/.local/state/ops-tab/actions-audit.jsonl`. That log is append-only and also records staged requests. The SOFware chip copies the handoff in the browser and does not call this route. The unknown chip is inert.

Nothing on the click posts, sends, merges, or starts a model turn. Quota, machine, and a waiting permission prompt stay inert text.

One repo's git failure does not blank the local cards. `worktrees`, `agents` and `needs_you` keep the repos that worked and carry the failing repo's message in `error`, prefixed with the repo name. Only a failure in every repo leaves the cards without data.

Local sources (worktrees, agents, smoke pings, machines) refresh every 5 seconds. Remote sources (worktree `gh pr list`, the `prs` card, the `linear` card, and the `quota` card) refresh every 120 seconds. The four remote legs run concurrently, so one slow vendor delays only itself. Smoke pings run on the local timer but at most every 30 seconds per app port.

## Quota card

The groups and their order come from the cache's `seats` list, which quartermaster's `seat_rows` writes and the status lines also draw. Five groups have their own builders here and always give the same eight seats: `cl` gives `claude_weekly` and `claude_fable`, `cx` gives `codex`, `cu` gives `cursor_models`, `cursor_other`, and `grokbot`, `gk` gives `supergrok`, and `mu` gives `muse`. Any other group, Google's `gg` today, gets one row per bar: the seat id is the bar's pool (`google_argon_week`), the label is the group's label plus the bar's (`Google · Argon weekly`), the text is the percent and `<pool>_pace`, and `vendor` and `subscription` set the row's hue and band. A pool seat-usage adds shows up with no change here. A cache with no `seats` list gets the five known groups. Values come from `~/.cache/seat-usage/latest.json`, written by `~/.local/bin/seat-usage`. The server never reads vendor tokens and never probes a model. A seat is `live` only when that field is in the cache. Otherwise it is `unknown` with `percent` null and note `seat-usage has no value`. Percentages are never estimated.

`claude_fable` is the exception. seat-usage writes `fable` only from a `weekly_scoped` limit, which Max has and Pro does not. When the Claude read succeeded (`as_of.claude` is set) and the plan is not Max, the seat is `absent`: text `not on Pro` for tier `claude_ai`, or `not on` plus the tier name, with a note that the slice is on Max. The row is a flat empty bar. It does not say the value is missing, and it does not show the reading's age. A missing `fable` on a Max tier (the tier name contains `max`) stays `unknown`. Claude labels follow the plan: `Claude Pro · weekly` and `Claude Pro · Fable slice` on `claude_ai`, `Claude Max · …` when the tier is Max. With no plan in the cache the label is `Claude · …`. Hovering Fable does not star the weekly row while the slice is `absent`; Other Models can still take it.

On each remote tick, if the cache file is missing or older than 600 seconds, the server starts `flock -n ~/.cache/seat-usage/.lock ~/.local/bin/seat-usage --quiet` in the background (90s `timeout`) and reads whatever cache exists now. It does not wait for the spawn. The lock file is the same one the Claude Code status line uses.

On that same tick the server runs `~/.local/bin/seat-usage --route host --cached --json` and stores the one row as `host_suggestion`: `suggestion`, `seat`, `family`, `effort`, `mode`, `reason`, `lean`, `reading_age_s`, and `selects`. The call is only ever made with `--cached`, so it reads the router's last answer and never calls a vendor. `selects` is false. The route suggests a host and does not choose one. A failed read, or a row that is not the host route, leaves `host_suggestion` null. The seats are unchanged either way.

The page shows that object as one line on the card. The name is the suggestion: `Grok Bot`, or `Opus` at the effort the router named, `on Max`. The router's `reason` has no host name, no effort, and no parentheses; the page adds one pair. An ordinary Bot suggestion reads `Next host: Grok Bot`. A weekly burn reads `Next host: Opus xhigh on Max (weekly all-models pool burning)`. When the router asks, the line is `Next host: ask (Bot over pace, Max 5h full) · lean Cursor Models, then SuperGrok`. `lean` is pool ids, Cursor Models then SuperGrok, with SuperGrok first only when that pool would otherwise expire. A muted line under it explains the call from the route's `hosts` entries: for each host passed over, the window that binds it and its percent, then, when the router asks, which pool to draw Grok from first. When `host_suggestion` is null, the line says there is no cached route. The line is text. Nothing on the page launches a session. The star on a family chip is still the first usable pool in `FAMILIES`, not this suggestion.

Cursor gets one seat per dashboard bar (`cursor_auto_pct` and `cursor_api_pct`), never `cursor_pct`, which is the higher of the two and hides Grok work on Cursor Models. `grokbot` is the Bot's weekly allowance (`bot_pct`); Cursor bills it, but it is on neither Cursor bar.

Each live seat carries `resets_at` and `window_s` from the cache's `*_reset_ts` and `*_window_s` (Claude has no window field, so its two seats use one week). The page shows the reset the way the status line does and marks the elapsed share of the window with a tick. Each seat's track is half the meter wide and slides so that tick sits on the meter's centre line, which every row shares: left of the line is the window so far, right of it the window still to come, and the track's right end is the cap. Fill past the line is ahead of pace and turns red, so the red length is how far over pace the seat is. A full pool is red throughout. A seat with no known window falls back to amber at 50% and red at 80%. The seats stack as rows with one shared scale, so the red lengths compare across pools. They keep the status line's order and pool hues (Claude orange, Codex purple, Cursor teal, Grok blue, Muse pink) as a faintly tinted band behind each pool's rows, edged in the pool's hue, with a gap between pools. The band lets the eye follow a row from label to text. The label column is as wide as its widest label and chips, the text column gets its full width next, and the bar takes what is left, so the text is cut only on a narrow window. The page's 1240px cap keeps the bar from growing far from its text. Grok Bot bills the Cursor seat, so it sits in Cursor's group. Rows never re-sort by pace, so a seat stays in one place. Each row's text is the percentage, `caps Nd early` when the current rate would empty the pool before the reset (its tooltip says when), any extra the server sends, and the reset day. The rail drops the server's pace words, since the arrow and tick carry them, and names the reading's age only once it is over 15 minutes old. That projection is skipped in the first tenth of a window, where one large job would project a cap that is not real.

A seat whose plan was set not to renew (`renews` false) and whose `renews_at` has passed shows a full grey, hatched bar and only `sub ended`: no usage, pace tick, caps, or reset. Its pool can still report numbers after the plan ends, but they no longer describe work you can do. It moves below the live seats, once, and adds no needs-you row. Its window does not count toward the shared time scale.

`claude_weekly` carries `five_hour` from `claude_5h` and `claude_5h_reset_ts`. `codex` carries it from `codex_5h` when the plan has a 5h window. `muse` carries it from `muse_5h` and `muse_5h_reset_ts`. Each is `percent`, `resets_at`, and `window_s` of 18000. The 5-hour window is too short to draw on the shared time scale, so it keeps the weekly track's width and its own pace tick sits on the same now line. That track is 3px and about half opacity; the weekly track stays 5px. It uses the same ink: red through the fill when full, and red past the pace tick when ahead. The row text still says `5h N%`, red on that same rule. A date-only term (`renews_date_only`, from a hand-kept `YYYY-MM-DD`) renders as `term ends Oct 14` through that Pacific calendar day, and a reset on that day or later is omitted. The stored timestamp is only the day's start, so the page compares the Pacific date, not that instant. `sub renewal due` starts the next Pacific day. A term that has a clock omits a reset only when the reset is after that time, and is due once that instant has passed.

A live seat at or above 80 percent adds a needs-you row, sorted last. SuperGrok's percent is the weekly pool (`grok_pct`, which `seat-usage` reads from `grok.com/rest/grok/credits` with the browser cookie). It adds a row when the cache says it is exhausted (`SuperGrok exhausted`): a 402 since the weekly reset, or the pool at 100 percent. The Bot adds `Grok Bot exhausted` when `bot_exhausted` is true. Pace never makes a row. Action is `/usage` for Claude, otherwise the tool's CLI name.

Each row's label carries a chip per model family the pool can serve: Fable and Opus on Claude's rows, Astra and Sol on Codex, Grok on Cursor Models and SuperGrok, Fable, Opus, and Sol on Other Models, Grok Bot on its own row, Wonder full and Wonder on Muse. A dashed chip is metered (Other Models); a dotted one is builder only (SuperGrok: no hosting, no chairing). Hovering or focusing a chip previews its family, clicking pins it, and clicking again or Esc clears it. The family's rows tint and the rest dim, and a star marks the first usable pool in the family's order: live, under its cap, on a plan that has not ended, and for Claude's rows with the weekly and 5h limits open. The mapping and order are the `FAMILIES` table at the top of `newtab.js`, a view of the routing in `~/.claude/CLAUDE.md`; `seat-usage --route` still decides a launch. A `$` chip shows in amber on a Cursor row or the Grok Bot row whose pool is capped, and on the Cursor rows whenever on-demand spend this cycle is above zero. It turns red past the on-demand limit. Its popover gives on-demand spend against its limit (`on_demand`, from `cursor_ondemand` and `cursor_ondemand_limit`), which is money past both bars and not part of either. The Bot bills that same on-demand once its weekly allowance runs out.

**Burn glow.** Each seat carries `burn`: `none`, `soft`, or `strong`. On the remote tick the server reads the last 128 KB of `~/.local/state/seat-usage/history.jsonl`, the line seat-usage's `record_pool` appends for every pool on each fresh read, and keeps rows with a numeric `used_pct` and `read_ts`. A pool is `soft` when its `used_pct` rose in the last 30 minutes: some reading in that window is above the last reading before it. It is `strong` when it is soft and it also rose at least one pace over the trailing two hours. Pace is 100 percent over the pool's `window_s`, so 20 points an hour on a 5h pool and about 0.6 on a weekly one. The rise runs from the last reading at or before two hours ago (or the first one there is) to the newest, divided by that span or two hours, whichever is longer. Only readings on the newest reading's reset (within an hour) count, so a reset is never a move. A pool whose newest reading is over 20 minutes old is `none`, and so is any seat that is not live. A seat takes the higher level of its pools: `claude_weekly` reads `claude weekly all` and `claude 5h`, `claude_fable` reads `claude weekly Fable`, `codex` reads `chatgpt weekly` and `chatgpt 5h`, the Cursor rows read `cursor models` and `cursor other models`, `grokbot` reads `grokbot week`, `supergrok` reads `grok week`, `muse` reads `muse weekly` and `muse 5h`, and a Google row reads `google <Label> weekly` or `5h` from its seat id. A missing or unreadable file is no burn, never an error.

Each seat also carries `burn_pph`: the fastest of those same pools, in percentage points per hour, over the last 30 minutes, rounded to one decimal. The base reading is the newest row on the current reset at or before 30 minutes ago. When none exists, the base is the oldest row on that reset inside the window, and the rise is divided by the full 30 minutes so a short history cannot overstate. A fall is 0. The field is nil when the newest reading is over 20 minutes old or there is no base. It is computed from the history rows already on disk. It does not change `burn`, and the page does not read usage any more often to get it.

The page adds `burn-soft` or `burn-strong` to a live row's class and `data-burn` to the row, and draws one static outline on both: a warm inset line, no animation, the same on soft and strong. The left edge stays the pool hue at 3px on every row. A strong burn does not thicken it. Every live row whose burn is `soft` or `strong` — the pool's usage rose in the last 30 minutes — gets a 6px round dot beside its percentage, whatever family it belongs to and whether or not it is the next host. A row that is not live, or whose burn is `none`, gets no coloured dot. Every row that shows a percent reserves that dot's box, margins included, so the percents share one column. On an inactive percent row the slot is empty (`dot-none`, `visibility: hidden`), `aria-hidden`, with no tooltip and no animation. A row with no percent — absent, unknown, or an ended plan — does not reserve the slot. The dot's colour comes only from `burn_pph`: green below 5 points per hour, yellow from 5 up to 15, and red at 15 and above. Pace, an early cap, and the percent do not colour it. A burning row with no `burn_pph` is green. The tooltip is `in use · 8.2 pts/hr`. The dot breathes on one clock for every row, opacity from .45 to 1 and a 3px ring of its colour at about 35 percent, `dot-breathe 2s ease-in-out infinite alternate`. Each rebuild sets `animation-delay` to minus the current time modulo 4 seconds, the round trip of that 2-second alternate, so the 5-second poll continues the same breath instead of cutting it. The dot is a deliberate exception and keeps breathing under `prefers-reduced-motion` (Ryan 2026-10-25). The row has no burn text; the detail tooltip keeps the level.

**Running now.** The quota card's data also carries `drivers`, built from the local sessions on every `/cards` compose, so it is as fresh as the agents card. It is one entry per tool with a `working` session: `label`, `pool`, and `sessions` (Claude Code on Claude, Codex on Codex, and the grok CLI on SuperGrok). It never carries a path, worktree, or session id. The page draws one line per entry under the rail, `Claude Code (2) · Claude`, and no block when the list is empty. Only this machine's sessions are listed.

Tests for the dot and list: `ruby tests/quota_test.rb` (levels, `burn_pph`, and drivers) and `node tests/burn_card_test.js` (the page, against a DOM stub, including the burn-rate colours, the wall-clock phase, and the reduced-motion exception).

`grokbot` on this card is only that weekly allowance. Whether a local-exec machine is linked to Grok Bot comes from a different cache (the machines card below), and only reaches the page as a needs-you row. The quota card does not read it.

## Machines card

Grok Bot local-exec hosts. Two signals, kept apart:

| Signal | Meaning |
|---|---|
| `link` | `connected`, `disconnected`, or `unknown`. Only Grok Bot knows this (ListMachines). A missing `link_as_of`, or one older than 30 minutes, is shown as `unknown`. |
| `heartbeat` | Age of the last line for that host in the Windows heartbeat log. Younger than 12 minutes is `live`. A missing file, or no line for that host, is `unknown` — not dead, and not a link. |

The page reads `~/.cache/grok-bot-fleet/machines.json` (`$GROK_BOT_FLEET_CACHE` overrides the path). Schema v1:

```json
{
  "v": 1,
  "as_of": "<iso>",
  "machines": [
    {
      "id": "surface",
      "label": "Surface",
      "expected_always_on": true,
      "link": "connected",
      "link_as_of": "<iso|null>",
      "heartbeat_last": "<iso|null>",
      "heartbeat_age_s": 42,
      "note": ""
    }
  ]
}
```

Link fields are written by Grok Bot link-watch / Cole, either into this file or into the sibling `links.json` in the same directory (`{ "v": 1, "machines": [ { "id", "link", "link_as_of" } ] }`). The newer `link_as_of` wins. Heartbeat fields are written by `~/.local/bin/grok-bot-machines`, which only parses the heartbeat log. It never turns a heartbeat into a link. If that log cannot be found or read, the helper leaves stored heartbeat fields alone. A missed Windows lookup is not an empty log. If the cache file is missing or older than 120 seconds, the server starts `flock -n ~/.cache/grok-bot-fleet/.lock ~/.local/bin/grok-bot-machines --quiet` in the background and serves whatever cache exists now.

The heartbeat log is the live install at `%USERPROFILE%\grok-bot-fleet\heartbeat.jsonl` (scheduled task `GrokBotFleetHeartbeat`, every 5 minutes). On WSL that is `/mnt/c/Users/<windows-user>/grok-bot-fleet/heartbeat.jsonl`. The reader asks `cmd.exe` for `USERPROFILE`, so a Windows user name that differs from the WSL user still resolves. `$GROK_BOT_FLEET_HEARTBEAT` overrides the path.

Hosts in `fleet_expected` are `expected_always_on`. A heartbeat line for any other host is kept with that flag false, so offline there is normal.

Each row shows the label, the heartbeat age, and a "not always-on" chip when that flag is false; a stored `note` is the row's tooltip. The card does not draw the Grok Bot link (there is no link chip or indicator). The effective link is still in the payload because the needs-you rule below uses it. A failed read keeps the last good machines payload and sets `error`. It does not blank the other cards. Before the first readable cache, the card still lists each `fleet_expected` host with heartbeat unknown, and the payload has link unknown (`cache_present: false`).

**Needs-you rule.** Only `expected_always_on` machines. Prefer a fresh link:

1. Effective link `disconnected` adds a row. The heartbeat is not consulted.
2. Otherwise, if the effective link is `unknown` and the heartbeat is dead (age ≥ 12 minutes), add a row. That row is host evidence while the bot link is unknown. It does not mean the bot reported a disconnect.
3. A fresh `connected` link does not add a row, even if the heartbeat is dead.

A missing heartbeat does not satisfy rule 2. Quota rows stay last; machine rows sort with the other needs-you rows by `since`.

Tests for this card: `node tests/machines_card_test.js` (the page, against a DOM stub) and `ruby tests/machines_test.rb` (the payload and the needs-you rule).

## Smoke pings

Every worktree row with an `app_port` (never a db port) gets `pings`: `GET http://127.0.0.1:<port><path>` with a 2 second timeout, no redirects. Green on 200 or 302.

Paths come from that repo's `pings` in the profile. A repo with none listed is pinged at `/login` only.

## systemd --user

`command -v ruby` is an asdf shim (`~/.asdf/shims/ruby`) that needs `asdf` on `PATH`. The unit calls the 3.4.3 binary directly. Do not enable this unit from a build session.

```bash
systemctl --user link "$PWD/orderly.service"
systemctl --user enable --now orderly.service
systemctl --user status orderly.service
```

## Pull requests card

Discovery (open PRs, limit 100 each):

```bash
gh search prs --author=@me --state=open --json number,title,repository,isDraft,url,updatedAt,createdAt
gh search prs --review-requested=@me --state=open --json number,title,repository,isDraft,url,updatedAt,createdAt,author
```

Then one `gh api graphql` call with aliases (`pr0: repository(...){ pullRequest(number: N) { ... } }`) for CI rollup, unresolved review threads, latest reviews, and review requests.

If that GraphQL call fails, the last good `prs` card is kept and `error` is set.

`review_requested_team` holds PRs where the request went to a team the viewer belongs to rather than to the viewer. The page shows it collapsed under the review tab, dimmed.

Mine-tab grouping: blocked on me (CI fail, unanswered threads, or changes requested), blocked on them (open threads I last commented on, reviews in, or reviewers requested), otherwise ready.

Every PR row carries `details`. It is `ok` when the GraphQL node resolved and `unknown` when it did not. CI, threads, reviews and review requests are all defaults on an `unknown` row, so that row groups as `unknown` instead of `ready`, and the page renders it under "Details unavailable" with a `details unavailable` chip. The green `ready` chip is reserved for the ready group; a blocked PR that is not a draft gets a neutral `ready` chip.

`requested_at` on the review-requested tab is always `null`. GraphQL does not expose the review-request timestamp without extra nested history, so `since` for that tab is the PR `created_at`. Review-requested needs-you rows only fire when that timestamp is older than one hour.

## Linear card

Assigned issues for the authenticated viewer, excluding completed and canceled. The API key is read from 1Password in process at boot (and again on a remote refresh only while it is missing). It is never written to the cache file, an env file, or logs.

If that read fails, `linear.error` is `no key in 1Password` and `data` is null; the other cards keep serving. If the GraphQL call fails, the last good `linear` card is kept and `error` is set.

Groups: waiting (a state whose name is in the profile's `waiting_states`), in progress (`state.type` started), next up (the profile's `next_up_label`, and no matching worktree), other. An empty `next_up_label` leaves that group unused.

`linear.data.mentions` holds recent Linear notifications: someone mentioned the viewer, or commented on the viewer's issue. Source is `notifications(first: 50)`, filtered to `issueCommentMention`, `issueMention`, `issueNewComment` and `issueCommentReply`, newest per issue, no older than 14 days, never the viewer's own action. A second query reads each issue's last 10 comments and drops any issue the viewer already replied to after the notification. `readAt` is deliberately ignored: read is not answered.

Needs-you rows from Linear: a mention or comment from `mentions`, and a waiting issue whose latest comment is not by the viewer. A mention takes priority over the waiting row for the same issue.

## Page

Open `extension/newtab.html` from `file://` (with `OPS_TAB_DEV=1`) or load `extension/` unpacked in Chrome. The page polls `/cards` every 5 seconds while visible.
