# frozen_string_literal: true

# Staged Needs-you packets. No network: Open3 is poisoned for this process.
# Run: ruby tests/needs_you_actions_test.rb
require "json"
require "open3"
require "tmpdir"
require "time"
require "minitest/autorun"

HOME_DIR = Dir.mktmpdir("orderly-actions-")
ENV["HOME"] = HOME_DIR
ENV["OPS_TAB_EXTENSION_ID"] = "test-extension"
ENV["OPS_TAB_DEV"] = "1"
PERSONAL_ROOT = File.join(HOME_DIR, "personal")
SOFWARE_ROOT = File.join(HOME_DIR, "sofware")
DECOY_ROOT = File.join(HOME_DIR, "decoy")
FileUtils.mkdir_p(File.join(HOME_DIR, ".config/ops-tab"))
File.write(File.join(HOME_DIR, ".config/ops-tab/profile.json"), JSON.dump({
  "github_org" => "not-a-lane",
  "viewer" => "me",
  "waiting_states" => ["review"],
  "repos" => [{ "name" => "decoy", "root" => DECOY_ROOT }],
  "personal_repos" => ["rymiwe/orderly", "bare-personal", "both"],
  "sofware_repos" => ["sofware/surface", "bare-sofware", "both"],
  "personal_linear_teams" => ["RYA"],
  "sofware_linear_teams" => ["SOF"],
  "personal_worktree_roots" => [PERSONAL_ROOT],
  "sofware_worktree_roots" => [SOFWARE_ROOT]
}))
require_relative ENV["ORDERLY_SERVER"] || "../server"
Minitest.after_run { FileUtils.rm_rf(HOME_DIR) }

# A stage that shells out fails the test instead of touching gh, op, or a model.
module NoExternal
  def popen3(*args, **_kwargs)
    raise "external popen3 #{args.inspect}"
  end

  def capture2(*args, **_kwargs)
    raise "external capture2 #{args.inspect}"
  end

  def capture3(*args, **_kwargs)
    raise "external capture3 #{args.inspect}"
  end

  def capture2e(*args, **_kwargs)
    raise "external capture2e #{args.inspect}"
  end
end
Open3.singleton_class.prepend(NoExternal)

TOKEN = "fixture-token"
ORIGIN = "chrome-extension://test-extension"
SINCE = "2026-10-24T12:00:00Z"

FakeReq = Struct.new(:request_method, :headers, :body) do
  def [](key)
    headers[key]
  end
end

class FakeRes
  attr_accessor :status, :body

  def initialize
    @headers = {}
    @status = nil
    @body = nil
  end

  def []=(key, value)
    @headers[key] = value
  end

  def [](key)
    @headers[key]
  end
end

class NeedsYouActionsTest < Minitest::Test
  def setup
    FileUtils.rm_rf(STAGED_DIR)
    FileUtils.rm_f(AUDIT_PATH)
  end

  def test_origin_token_and_content_type_rejections
    server = personal_server
    key = personal_key(server)
    [
      { origin: :omit },
      { origin: "null" },
      { origin: "https://evil.example" },
      { origin: "http://127.0.0.1:5180" },
      { token: :omit },
      { token: "wrong-token" },
      { content_type: :omit },
      { content_type: "text/plain" }
    ].each do |opts|
      before = disk_snapshot
      res = post(server, key, "loop", **opts)
      assert_includes [403, 415], res.status, opts.inspect
      refute_equal 200, res.status
      assert_equal before, disk_snapshot, opts.inspect
    end
  end

  def test_get_and_options_write_nothing
    server = personal_server
    key = personal_key(server)
    body = JSON.generate({ "row_key" => key, "action" => "loop" })
    before = disk_snapshot
    res = call(server, "GET", body: body)
    assert_equal 405, res.status
    assert_equal before, disk_snapshot

    opt = call(server, "OPTIONS", body: body)
    assert_equal 204, opt.status
    assert_equal before, disk_snapshot

    bad = call(server, "OPTIONS", body: body, origin: "null")
    assert_equal 403, bad.status
    assert_equal before, disk_snapshot
  end

  def test_json_charset_is_accepted
    server = personal_server
    res = post(server, personal_key(server), "loop", content_type: "application/json; charset=utf-8")
    assert_equal 200, res.status
    refute_empty staged_entries
  end

  def test_host_pin_writes_nothing
    server = personal_server
    key = personal_key(server)
    before = disk_snapshot
    res = post(server, key, "loop", host: "evil.example")
    assert_equal 403, res.status
    assert_equal before, disk_snapshot
  end

  def test_sofware_and_unknown_write_no_packet
    server = mixed_server
    sofware = rows_of(server).find { |row| row["lane"] == "sofware" && row["kind"] == "pr" }
    unknown = rows_of(server).find { |row| row["lane"] == "unknown" && row["kind"] == "pr" }
    refute_nil sofware
    refute_nil unknown
    assert_empty sofware["actions"]
    assert_empty unknown["actions"]
    text = sofware.dig("wes", "copy_text").to_s
    assert_includes text, "[SOFware handoff]"
    assert_includes text, "reason: ci_fail"
    refute_includes text, SOFWARE_ROOT
    refute_includes text, "BLD"
    assert_nil sofware["path"]

    sof = post(server, sofware["row_key"], "loop")
    assert_equal 422, sof.status
    assert_equal "lane sofware", JSON.parse(sof.body)["error"]
    unk = post(server, unknown["row_key"], "council")
    assert_equal 422, unk.status
    assert_equal "lane unknown", JSON.parse(unk.body)["error"]
    assert_empty staged_entries
    lines = audit_lines
    assert_equal %w[refused_lane refused_lane], lines.map { |line| line["status"] }
    assert_equal ["lane sofware", "lane unknown"], lines.map { |line| line["error"] }
    again = rows_of(server)
    shown = again.find { |row| row["row_key"] == sofware["row_key"] }
    assert_equal "refused_lane", shown.dig("last_action", "status")
    assert_equal "lane sofware", shown.dig("last_action", "error")
  end

  def test_packet_is_the_cached_row_only
    server = personal_server
    row = rows_of(server).find { |item| item["subkind"] == "ci_fail" }
    res = post(server, row["row_key"], "loop")
    assert_equal 200, res.status
    body = JSON.parse(res.body)
    assert_equal true, body["ok"]
    slug = server.send(:stage_slug, row["row_key"])
    packet = JSON.parse(File.read(File.join(STAGED_DIR, "#{slug}.json")))
    brief = File.read(File.join(STAGED_DIR, "#{slug}.md"))
    assert_equal "CACHED-TITLE-ONLY", packet["title"]
    assert_equal "https://github.com/rymiwe/orderly/pull/12", packet["url"]
    assert_equal File.join(PERSONAL_ROOT, "orderly"), packet["path"]
    assert_equal "loop", packet["action"]
    assert_includes brief, "CACHED-TITLE-ONLY"
    assert_includes brief, "Nothing is posted"
    refute_includes brief, "fixture-token"
    cmd = body["run_cmd"]
    assert_includes cmd, File.join(STAGED_DIR, "#{slug}.md")
    assert_includes cmd, File.join(STAGED_DIR, "#{slug}.status.json")
    %w[gh op claude codex linear].each { |word| refute_match(/\b#{word}\b/, cmd) }
    assert_equal 0, run_shell(cmd)
    refute File.file?(server.send(:status_path_for, row["row_key"]))
  end

  def test_failure_status_round_trip_and_reset
    server = personal_server
    row = rows_of(server).find { |item| item["subkind"] == "ci_fail" }
    key = row["row_key"]
    res = post(server, key, "loop")
    cmd = JSON.parse(res.body)["run_cmd"]
    assert_equal 1, run_shell(with_exit(cmd, 1))
    failed = rows_of(server).find { |item| item["row_key"] == key }
    assert_equal "failed", failed.dig("last_action", "status")
    assert_equal 1, failed.dig("last_action", "code")
    assert_equal "loop", failed.dig("last_action", "action")
    # A fresh read, as a reload would do.
    again = rows_of(server).find { |item| item["row_key"] == key }
    assert_equal 1, again.dig("last_action", "code")

    assert_equal 4, run_shell(with_exit(cmd, 4))
    newer = rows_of(server).find { |item| item["row_key"] == key }
    assert_equal 4, newer.dig("last_action", "code")
    stored = JSON.parse(File.read(server.send(:status_path_for, key)))
    assert_equal 4, stored["code"]
    assert_equal SINCE, stored["since"]

    # Re-stage clears the pill. The next failure is the only one shown.
    assert_equal 200, post(server, key, "loop").status
    cleared = rows_of(server).find { |item| item["row_key"] == key }
    assert_nil cleared["last_action"]
    refute File.file?(server.send(:status_path_for, key))
    cmd = JSON.parse(post(server, key, "loop").body)["run_cmd"]
    # The post above staged again; run the command from that response.
    # post was called twice. Use the latest command.
    assert_equal 9, run_shell(with_exit(cmd, 9))
    current = rows_of(server).find { |item| item["row_key"] == key }
    assert_equal 9, current.dig("last_action", "code")

    # A new since drops the old status and any audit line from the old since.
    prs = server.instance_variable_get(:@sources).dig("prs", "data")
    prs["mine"][0]["ci_failed_at"] = "2026-10-25T01:00:00Z"
    File.open(AUDIT_PATH, "a") do |file|
      file.write(JSON.generate({
        "ts" => "2026-10-24T12:00:01Z", "row_key" => key, "status" => "refused_lane",
        "error" => "lane unknown", "since" => SINCE, "action" => "loop"
      }) + "\n")
    end
    moved = rows_of(server).find { |item| item["subkind"] == "ci_fail" }
    assert_nil moved["last_action"]
    assert File.file?(server.send(:status_path_for, key))
  end

  def test_lanes_are_allowlists
    server = mixed_server
    lanes = rows_of(server).to_h { |row| [row["row_key"], row["lane"]] }
    assert_equal "personal", lanes["pr:rymiwe/orderly:#12:ci_fail"]
    assert_equal "personal", lanes["pr:bare-personal:#3:ci_fail"]
    assert_equal "sofware", lanes["pr:sofware/surface:#9:ci_fail"]
    assert_equal "sofware", lanes["pr:bare-sofware:#4:ci_fail"]
    assert_equal "unknown", lanes["pr:both:#5:ci_fail"]
    assert_equal "unknown", lanes["pr:decoy:#6:ci_fail"]
    assert_equal "unknown", lanes["pr:app:#7:ci_fail"]
    assert_equal "personal", lanes["linear:RYA:RYA-4:mention"]
    assert_equal "sofware", lanes["linear:SOF:SOF-3:waiting"]
    assert_equal "unknown", lanes["linear:RYA:SOF-1:waiting"]
    assert_equal "personal", lanes["agent:orderly:grok:unconfirmed"]
    assert_equal "sofware", lanes["agent:surface-wt:grok:unconfirmed"]
    assert_equal "unknown", lanes["agent:decoy-wt:grok:unconfirmed"]
    assert_nil lanes["quota:Claude:Claude:usage"]
    waiting = rows_of(server).find { |row| row["subkind"] == "waiting" && row["kind"] == "agent" }
    assert_equal "personal", waiting["lane"]
    assert_empty waiting["actions"]
  end

  def test_personal_actions_follow_kind
    server = mixed_server
    actions = rows_of(server).to_h { |row| [row["row_key"], (row["actions"] || []).map { |item| item["id"] }] }
    assert_equal %w[loop], actions["pr:rymiwe/orderly:#12:ci_fail"]
    assert_equal %w[draft], actions["pr:rymiwe/orderly:#12:threads"]
    assert_equal %w[loop council], actions["pr:rymiwe/orderly:#12:changes_requested"]
    assert_equal %w[council draft], actions["pr:rymiwe/orderly:#8:review_requested"]
    assert_equal %w[draft council], actions["linear:RYA:RYA-4:mention"]
    assert_equal %w[resume loop], actions["agent:orderly:grok:unconfirmed"]
    assert_empty actions["pr:sofware/surface:#9:ci_fail"]
    assert_empty actions["agent:orderly:claude:waiting"]
    quota = rows_of(server).find { |row| row["kind"] == "quota" }
    assert_empty quota["actions"]
    assert_nil quota["lane"]
    assert_nil quota["wes"]

    refused = post(server, "agent:orderly:claude:waiting", "loop")
    assert_equal 422, refused.status
    assert_empty staged_entries
    assert_equal "refused_action", audit_lines.last["status"]
  end

  def disk_snapshot
    [staged_entries, File.file?(AUDIT_PATH) ? File.read(AUDIT_PATH) : ""]
  end

  def staged_entries
    Dir.exist?(STAGED_DIR) ? Dir.children(STAGED_DIR).sort : []
  end

  def audit_lines
    return [] unless File.file?(AUDIT_PATH)

    File.readlines(AUDIT_PATH, chomp: true).map { |line| JSON.parse(line) }
  end

  def personal_key(server)
    rows_of(server).find { |row| row["subkind"] == "ci_fail" }["row_key"]
  end

  def rows_of(server)
    server.send(:cached_needs_rows_unlocked)
  end

  def with_exit(cmd, code)
    flunk "run command does not start with cat" unless cmd.start_with?("cat -- ")

    cmd.sub(/\Acat -- \S+/, "(exit #{Integer(code)})")
  end

  def run_shell(cmd)
    system("bash", "-c", cmd, out: File::NULL, err: File::NULL)
    $?.exitstatus
  end

  def post(server, row_key, action, **opts)
    call(server, "POST", body: JSON.generate({ "row_key" => row_key, "action" => action }), **opts)
  end

  def call(server, method, body: "", origin: ORIGIN, token: TOKEN, content_type: "application/json", host: "127.0.0.1")
    headers = { "Host" => host }
    headers["Origin"] = origin unless origin == :omit
    headers["Content-Type"] = content_type unless content_type == :omit
    headers["X-Orderly-Token"] = token unless token == :omit
    res = FakeRes.new
    server.send(:handle_stage, FakeReq.new(method, headers, body), res)
    res
  end

  def personal_server
    build_server(
      prs: { "mine" => [ci_pr("orderly", "rymiwe/orderly", 12, "CACHED-TITLE-ONLY")], "review_requested" => [] },
      worktrees: [wt_row("pr-12", "orderly", File.join(PERSONAL_ROOT, "orderly"))],
      pr_maps: { "orderly" => pr_map(12) }
    )
  end

  def mixed_server
    build_server(
      prs: {
        "mine" => [
          ci_pr("orderly", "rymiwe/orderly", 12, "CACHED-TITLE-ONLY").merge(
            "threads_awaiting_me" => 2,
            "threads_last_by" => "sam",
            "thread_comment_url" => "https://github.com/rymiwe/orderly/pull/12#discussion",
            "thread_comment_at" => SINCE,
            "review_decision" => "CHANGES_REQUESTED",
            "changes_requested_by" => "sam",
            "changes_requested_at" => SINCE
          ),
          ci_pr("bare-personal", "", 3, "bare"),
          ci_pr("surface", "sofware/surface", 9, "surface work"),
          ci_pr("bare-sofware", "", 4, "bare sof"),
          ci_pr("both", "", 5, "both lists"),
          ci_pr("decoy", "", 6, "home repo is not a lane"),
          ci_pr("app", "", 7, "org is not a lane")
        ],
        "review_requested" => [{
          "number" => 8,
          "repo" => "orderly",
          "name_with_owner" => "rymiwe/orderly",
          "title" => "Please review",
          "url" => "https://github.com/rymiwe/orderly/pull/8",
          "draft" => false,
          "created_at" => "2026-10-01T00:00:00Z",
          "since" => "2026-10-20T00:00:00Z",
          "updated_at" => "2026-10-24T00:00:00Z",
          "author" => "sam",
          "requested_by" => "sam"
        }]
      },
      linear: {
        "mentions" => [{
          "issue_id" => "RYA-4",
          "kind" => "mention",
          "actor" => "Ada",
          "excerpt" => "look",
          "at" => SINCE,
          "comment_url" => "https://linear.app/issue/RYA-4"
        }],
        "mine" => [
          {
            "id" => "SOF-3",
            "title" => "Surface ticket",
            "url" => "https://linear.app/issue/SOF-3",
            "team" => "SOF",
            "state" => "Review",
            "state_type" => "started",
            "labels" => [],
            "last_comment_by" => "Bea",
            "last_comment_at" => SINCE,
            "last_comment_mine" => false,
            "last_comment_excerpt" => "why"
          },
          {
            "id" => "SOF-1",
            "title" => "Disagreement",
            "url" => "https://linear.app/issue/SOF-1",
            "team" => "RYA",
            "state" => "Review",
            "state_type" => "started",
            "labels" => [],
            "last_comment_by" => "Bea",
            "last_comment_at" => SINCE,
            "last_comment_mine" => false,
            "last_comment_excerpt" => "which lane"
          }
        ]
      },
      sessions: [
        session("grok", "unconfirmed", "orderly", File.join(PERSONAL_ROOT, "orderly")),
        session("grok", "unconfirmed", "surface-wt", File.join(SOFWARE_ROOT, "surface")),
        session("grok", "unconfirmed", "decoy-wt", File.join(DECOY_ROOT, "decoy")),
        session("claude", "waiting", "orderly", File.join(PERSONAL_ROOT, "orderly"))
      ],
      quota: {
        "seats" => [{
          "seat" => "claude_weekly",
          "label" => "Claude · weekly",
          "status" => "live",
          "percent" => 90,
          "text" => "90%",
          "verified_at" => SINCE,
          "renews" => true
        }]
      },
      worktrees: [
        wt_row("pr-12", "orderly", File.join(PERSONAL_ROOT, "orderly")),
        wt_row("pr-9", "surface", File.join(SOFWARE_ROOT, "surface"))
      ],
      pr_maps: {
        "orderly" => pr_map(12),
        "surface" => pr_map(9)
      }
    )
  end

  def ci_pr(repo, nwo, number, title)
    {
      "number" => number,
      "repo" => repo,
      "name_with_owner" => nwo,
      "title" => title,
      "url" => nwo.empty? ? "https://example.test/#{repo}/pull/#{number}" : "https://github.com/#{nwo}/pull/#{number}",
      "ci" => "fail",
      "ci_url" => "https://example.test/checks/#{number}",
      "ci_failed_name" => "unit",
      "ci_failed_at" => SINCE,
      "since" => SINCE,
      "threads_awaiting_me" => 0,
      "review_decision" => nil,
      "draft" => false,
      "created_at" => "2026-10-01T00:00:00Z",
      "updated_at" => SINCE
    }
  end

  def session(tool, state, worktree, cwd)
    {
      "tool" => tool,
      "state" => state,
      "worktree" => worktree,
      "cwd" => cwd,
      "detail" => state,
      "updated_at" => SINCE
    }
  end

  def wt_row(name, repo, path)
    {
      "name" => name,
      "repo" => repo,
      "path" => path,
      "branch" => "topic",
      "detached" => false,
      "is_main" => false,
      "app_port" => nil,
      "last_session_at" => nil,
      "merged_into_develop" => nil
    }
  end

  def pr_map(number)
    {
      "by_branch" => {},
      "by_number" => { number => { "number" => number, "state" => "OPEN", "isDraft" => false, "url" => "https://example.test/#{number}" } },
      "loaded" => true
    }
  end

  def build_server(prs:, linear: nil, sessions: nil, quota: nil, worktrees: nil, pr_maps: nil)
    server = OpsTabServer.allocate
    server.instance_variable_set(:@mutex, Mutex.new)
    server.instance_variable_set(:@action_token, TOKEN)
    server.instance_variable_set(:@pr_maps, pr_maps || {})
    server.instance_variable_set(:@ping_cache, {})
    %i[@local_error @remote_error @prs_error @linear_error @quota_error @machines_error].each do |ivar|
      server.instance_variable_set(ivar, nil)
    end
    server.instance_variable_set(:@sources, {
      "local" => { "data" => { "rows" => worktrees || [], "sessions" => sessions || [] }, "fetched_at" => SINCE },
      "pings" => { "data" => {}, "fetched_at" => SINCE },
      "prs" => { "data" => prs, "fetched_at" => SINCE },
      "linear" => { "data" => linear, "fetched_at" => linear && SINCE },
      "quota" => { "data" => quota, "fetched_at" => quota && SINCE },
      "machines" => { "data" => nil, "fetched_at" => nil }
    })
    server
  end
end
