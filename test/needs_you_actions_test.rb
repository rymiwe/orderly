# frozen_string_literal: true

# Needs-you actions: team-ask rows, overlay hide/snooze, summary, adapters.
# No network. Run: ruby test/needs_you_actions_test.rb
require "fileutils"
require "json"
require "stringio"
require "tmpdir"
require "time"
require "minitest/autorun"

HOME_DIR = Dir.mktmpdir("orderly-needs-you-actions-")
ENV["HOME"] = HOME_DIR
ENV["OPS_TAB_OVERLAY_PATH"] = File.join(HOME_DIR, "needs-you-overlay.json")
FileUtils.mkdir_p(File.join(HOME_DIR, ".config/ops-tab"))
File.write(
  File.join(HOME_DIR, ".config/ops-tab/profile.json"),
  JSON.dump({ "viewer" => "tester" })
)
require_relative "../server"
Minitest.after_run { FileUtils.rm_rf(HOME_DIR) }

class NeedsYouActionsTest < Minitest::Test
  NOW = Time.utc(2026, 10, 21, 12, 0, 0)

  def server
    OpsTabServer.allocate
  end

  def test_unreadable_overlay_file_loads_empty_and_is_left_alone
    skip "root can read a mode-000 file" if Process.uid.zero?

    had = File.file?(OVERLAY_PATH)
    saved = had ? File.binread(OVERLAY_PATH) : nil
    body = JSON.generate({ "version" => 1, "entries" => { "github:acme/widgets#9:review" => { "mode" => "pending" } } })
    FileUtils.mkdir_p(File.dirname(OVERLAY_PATH))
    File.write(OVERLAY_PATH, body)
    File.chmod(0o000, OVERLAY_PATH)
    begin
      s = server
      _out, err = capture_io { s.send(:load_overlay) }
      assert_equal({ "version" => 1, "entries" => {} }, s.instance_variable_get(:@overlay))
      assert_match(/needs-you overlay left unread: Errno::EACCES/, err)
      assert_equal 1, err.lines.size
      assert File.file?(OVERLAY_PATH)
      assert_equal 0, File.stat(OVERLAY_PATH).mode & 0o777
      File.chmod(0o600, OVERLAY_PATH)
      assert_equal body, File.read(OVERLAY_PATH)
    ensure
      File.chmod(0o600, OVERLAY_PATH) if File.exist?(OVERLAY_PATH)
      if had
        File.binwrite(OVERLAY_PATH, saved)
      else
        FileUtils.rm_f(OVERLAY_PATH)
      end
    end
  end

  def ago(seconds, now = Time.now.utc)
    (now - seconds).utc.iso8601
  end

  def test_hide_returns_on_the_next_refresh_and_stays_gone_when_the_ask_is_gone
    s = server
    key = "github:acme/widgets#4:review"
    row = need(key, "oid:aaa|thread:https://example.test/t/1|issue:https://example.test/c/1")
    entry = pending(key, at: NOW - 30, source_fetched_at: NOW - 120)
    entries = { key => entry }

    # A refresh that started before the click does not confirm, even if it
    # finishes after the click (opinion 5).
    visible, kept, = s.send(:project_overlay, [row], entries, avail("github", fetched: NOW + 5, started: NOW - 60), NOW)
    assert_empty visible
    assert kept.key?(key)

    # No start stamp: fetched_at has to be after the click. This refresh is
    # newer than the stored snapshot and still older than the click.
    visible, kept, = s.send(:project_overlay, [row], entries, avail("github", fetched: NOW - 60), NOW)
    assert_empty visible
    assert kept.key?(key)

    # The next refresh started after the click and the ask is still there.
    visible, kept, pending_keys, = s.send(:project_overlay, [row], entries, avail("github", fetched: NOW + 20, started: NOW + 10), NOW + 20)
    assert_equal [key], visible.map { |r| r["clear_key"] }
    refute kept.key?(key)
    assert_empty pending_keys

    # Same outcome with only a post-click fetched_at (no start stamp).
    visible, kept, = s.send(:project_overlay, [row], entries, avail("github", fetched: NOW + 20), NOW + 20)
    assert_equal [key], visible.map { |r| r["clear_key"] }
    refute kept.key?(key)

    # The ask is gone on a loaded source: the entry is dropped and stays gone.
    visible, kept, = s.send(:project_overlay, [], entries, avail("github", fetched: NOW + 20, started: NOW + 10), NOW + 20)
    assert_empty visible
    refute kept.key?(key)
  end

  def test_snooze_until_a_time_hides_before_and_returns_after
    s = server
    key = "github:acme/widgets#4:review"
    row = need(key, "oid:aaa")
    entry = {
      "mode" => "until",
      "at" => (NOW - 3600).iso8601,
      "until" => (NOW + 3600).iso8601,
      "token" => "oid:old",
      "source_fetched_at" => (NOW - 7200).iso8601,
      "source" => "github"
    }
    # A new commit does not wake a timed snooze.
    moved = row.merge("change_token" => "oid:bbb")
    visible, kept, _, snoozed = s.send(:project_overlay, [moved], { key => entry }, avail("github", fetched: NOW), NOW)
    assert_empty visible
    assert_equal 1, snoozed
    assert kept.key?(key)

    later = NOW + 3600
    visible, kept, = s.send(:project_overlay, [moved], { key => entry }, avail("github", fetched: later), later)
    assert_equal [key], visible.map { |r| r["clear_key"] }
    refute kept.key?(key)
  end

  def test_snooze_until_change_wakes_on_commit_or_comment_and_caps_at_14_days
    s = server
    base = token_pr
    same = s.send(:github_review_token, base)
    new_commit = s.send(:github_review_token, base.merge("head_oid" => "deadbeef"))
    new_comment = s.send(:github_review_token, base.merge("issue_comment_url" => "https://example.test/c/9"))
    new_thread = s.send(:github_review_token, base.merge("latest_thread_comment_url" => "https://example.test/t/9"))
    renamed = s.send(:github_review_token, base.merge("title" => "renamed", "updated_at" => ago(30, NOW)))
    refute_equal same, new_commit
    refute_equal same, new_comment
    refute_equal same, new_thread
    assert_equal same, renamed
    assert_includes new_commit, "oid:deadbeef"
    assert_includes new_comment, "issue:https://example.test/c/9"

    key = "github:acme/widgets#4:review"
    entry = {
      "mode" => "until_change",
      "at" => (NOW - 2 * 86_400).iso8601,
      "until" => nil,
      "token" => same,
      "source_fetched_at" => (NOW - 3 * 86_400).iso8601,
      "source" => "github"
    }
    hidden, kept, _, snoozed = s.send(:project_overlay, [need(key, same)], { key => entry }, avail("github", fetched: NOW), NOW)
    assert_empty hidden
    assert_equal 1, snoozed
    assert kept.key?(key)

    woken, kept, = s.send(:project_overlay, [need(key, new_commit)], { key => entry }, avail("github", fetched: NOW), NOW)
    assert_equal [key], woken.map { |r| r["clear_key"] }
    refute kept.key?(key)

    woken, = s.send(:project_overlay, [need(key, new_comment)], { key => entry }, avail("github", fetched: NOW), NOW)
    assert_equal [key], woken.map { |r| r["clear_key"] }

    cap_at = NOW - UNTIL_CHANGE_BACKSTOP
    expired = entry.merge("at" => cap_at.iso8601)
    shown, kept, = s.send(:project_overlay, [need(key, same)], { key => expired }, avail("github", fetched: NOW), NOW)
    assert_equal [key], shown.map { |r| r["clear_key"] }
    refute kept.key?(key)

    still = entry.merge("at" => (cap_at + 60).iso8601)
    hidden, kept, = s.send(:project_overlay, [need(key, same)], { key => still }, avail("github", fetched: NOW), NOW)
    assert_empty hidden
    assert kept.key?(key)
  end

  def test_team_row_predicate_names_every_team_and_ignores_the_card_cap
    s = server
    assert s.send(:team_ask_visible?, team_pr)
    refute s.send(:team_ask_visible?, team_pr("draft" => true))
    refute s.send(:team_ask_visible?, team_pr("labels" => ["Prototype"]))
    refute s.send(:team_ask_visible?, team_pr("labels" => ["prototype"]))
    assert s.send(:team_ask_visible?, team_pr("labels" => ["prototype-extra"]))
    refute s.send(:team_ask_visible?, team_pr("updated_at" => ago(8 * 86_400)))
    refute s.send(:team_ask_visible?, team_pr("reviews_empty" => false))
    refute s.send(:team_ask_visible?, team_pr("reviews_empty" => nil))
    refute s.send(:team_ask_visible?, team_pr("labels" => nil))
    # No hour of grace. A team ask updated a minute ago is shown.
    assert s.send(:team_ask_visible?, team_pr("updated_at" => ago(60), "since" => ago(60)))

    both = team_pr(
      "team_reviewers" => [
        { "slug" => "platform", "name" => "Platform" },
        { "slug" => "frontend", "name" => "Frontend" }
      ]
    )
    rows = s.send(:needs_you_team, both, [])
    assert_equal 1, rows.length
    assert_equal "team_ask", rows[0]["tier"]
    assert_equal true, rows[0]["dim"]
    assert_equal "frontend,platform", rows[0]["ask_from"]
    assert_equal "github:acme/widgets#8:team", rows[0]["clear_key"]
    assert_includes rows[0]["title"], "Frontend"
    assert_includes rows[0]["title"], "Platform"
    assert_includes rows[0]["change_token"], "teams:frontend,platform"

    card = (1..15).map { |n| { "number" => n } }
    candidates = (1..16).map { |n| team_pr("number" => n, "title" => "ask #{n}") }
    packed = s.send(:pack_review_snapshot, [], [], card, candidates, 16)
    assert_equal 15, packed["review_requested_team"].length
    assert_equal 16, packed["team_ask_candidates"].length
    built = s.send(:needs_you_from_prs, {
      "mine" => [],
      "review_requested" => [],
      "review_requested_team" => packed["review_requested_team"],
      "team_ask_candidates" => packed["team_ask_candidates"]
    }, [])
    assert_equal 16, built.length
    assert_equal ["github:acme/widgets#16:team"], built.select { |r| r["id"] == "#16" }.map { |r| r["clear_key"] }
    refute_includes packed["review_requested_team"].map { |r| r["number"] }, 16
    assert_includes PR_GQL_FIELDS, "labels(first:10)"
    assert_includes PR_GQL_FIELDS, "comments(last:1)"
    assert_includes PR_GQL_FIELDS, "oid"
  end

  def test_delete_guard_drops_an_entry_only_when_its_own_source_loaded
    s = server
    github_key = "github:acme/widgets#4:review"
    linear_key = "linear:ZZ-1:mention"
    entries = {
      github_key => pending(github_key, source: "github"),
      linear_key => pending(linear_key, source: "linear")
    }
    none = {
      "github" => { "loaded" => false },
      "linear" => { "loaded" => false }
    }
    _, kept, = s.send(:project_overlay, [], entries, none, NOW)
    assert_equal [github_key, linear_key].sort, kept.keys.sort

    linear_only = none.merge("linear" => { "loaded" => true, "fetched_at" => NOW.iso8601 })
    _, kept, = s.send(:project_overlay, [], entries, linear_only, NOW)
    assert kept.key?(github_key)
    refute kept.key?(linear_key)

    github_loaded = {
      "github" => { "loaded" => true, "fetched_at" => (NOW + 30).iso8601, "refresh_started_at" => (NOW + 10).iso8601 }
    }
    row = need(github_key, "oid:aaa")
    visible, kept, = s.send(:project_overlay, [row], { github_key => entries[github_key] }, github_loaded, NOW + 30)
    assert_equal [github_key], visible.map { |r| r["clear_key"] }
    refute kept.key?(github_key)
  end

  def test_summary_is_counts_only_and_matches_the_visible_list
    s = server
    now = NOW
    visible = [
      row_for_summary("direct_ask", "github", now - 2 * 3600, "zz-title-direct", "https://zz.example/pr", "zz-login", "zz-acme/widgets"),
      row_for_summary("blocked_on_me", "github", now - 2 * 86_400, "zz-title-ci", "https://zz.example/ci", "zz-login", "zz-acme/widgets"),
      row_for_summary("team_ask", "github", now - 4 * 86_400, "zz-title-team", "https://zz.example/team", "zz-team-slug", "zz-acme/widgets"),
      row_for_summary("informational", "quota", now - 8 * 86_400, "zz-title-quota", "https://zz.example/quota", "zz-login", "zz-seat"),
      row_for_summary("direct_ask", "linear", "not-a-time", "zz-title-bad-since", "https://zz.example/linear", "zz-login", "zz-issue")
    ]
    body = s.send(:summary_from, visible, 2, 3, now)
    assert_equal({ "direct" => 2, "blocked" => 1, "team" => 1, "info" => 1 }, body["tiers"])
    assert_equal({ "github" => 3, "linear" => 1, "agent" => 0, "quota" => 1, "machine" => 0, "slack" => 0 }, body["sources"])
    assert_equal({ "lt_1d" => 1, "d1_3" => 1, "d3_7" => 1, "gt_7d" => 1 }, body["ages"])
    assert_equal 8 * 86_400, body["oldest_age_s"]
    assert_equal 2, body["pending"]
    assert_equal 3, body["snoozed"]
    encoded = JSON.generate(body)
    %w[zz-title-direct zz-title-ci zz-title-team zz-title-quota zz-title-bad-since https://zz.example zz-login zz-team-slug zz-acme zz-seat zz-issue clear_key ask_from].each do |secret|
      refute_includes encoded, secret
    end
    body.each_value do |value|
      if value.is_a?(Hash)
        value.each_value { |n| assert_kind_of Integer, n }
      else
        assert value.nil? || value.is_a?(Integer)
      end
    end

    odd = s.send(:summary_from, [{
      "tier" => "zz-not-a-tier",
      "source" => "zz-source",
      "since" => (now - 50).iso8601,
      "title" => "zz-title-odd",
      "clear_key" => "github:zz-acme/widgets#1:review"
    }], 0, 0, now)
    assert_equal 50, odd["oldest_age_s"]
    assert_equal 0, odd["tiers"].values.sum
    encoded = JSON.generate(odd)
    refute_includes encoded, "zz-not-a-tier"
    refute_includes encoded, "zz-source"
    refute_includes encoded, "zz-title-odd"
    refute_includes encoded, "zz-acme"
  end

  def test_adapter_fetch_is_normalized_and_slack_is_empty
    s = server
    adapters = s.send(:needs_you_adapters)
    assert_equal %w[github linear agent machine quota slack], adapters.map(&:source_id)
    slack = adapters.find { |a| a.source_id == "slack" }
    ctx = NeedsYou::MemoryContext.new(snapshots: { "slack" => { "messages" => [{ "text" => "zz-slack" }] } }, worktrees: [])
    assert_equal [], slack.fetch(ctx)
    assert_equal [], slack.fetch(NeedsYou::MemoryContext.new(snapshots: { "slack" => nil }, worktrees: []))

    prs = {
      "mine" => [],
      "review_requested" => [direct_pr],
      "review_requested_team" => [],
      "team_ask_candidates" => [team_pr]
    }
    github = adapters.find { |a| a.source_id == "github" }
    rows = github.fetch(NeedsYou::MemoryContext.new(snapshots: { "prs" => prs }, worktrees: []))
    assert_equal 2, rows.length
    rows.each do |row|
      %w[kind tier since clear_key].each { |field| assert row.key?(field), field }
      refute_nil row["since"]
    end
    direct = rows.find { |r| r["clear_key"].end_with?(":review") }
    team = rows.find { |r| r["clear_key"].end_with?(":team") }
    assert_equal "pr", direct["kind"]
    assert_equal "direct_ask", direct["tier"]
    assert_equal "direct", direct["ask_from"]
    assert_equal "team_ask", team["tier"]
    assert_equal true, team["dim"]
    assert_equal "github", team["source"]
  end

  def test_overlay_post_copies_the_token_and_summary_route_hides_it
    s = boot
    key = "github:acme/widgets#4:review"
    pr = direct_pr.merge(
      "title" => "zz-title-route",
      "url" => "https://zz.example/route",
      "author" => "zz-login",
      "requested_by" => "zz-login",
      "requested_at" => (NOW - 3 * 3600).iso8601,
      "since" => (NOW - 3 * 3600).iso8601,
      "created_at" => (NOW - 5 * 86_400).iso8601,
      "updated_at" => (NOW - 2 * 86_400).iso8601,
      "head_oid" => "abc",
      "latest_thread_comment_url" => "https://zz.example/t",
      "issue_comment_url" => "https://zz.example/c"
    )
    s.instance_variable_get(:@sources)["prs"] = {
      "data" => { "mine" => [], "review_requested" => [pr], "team_ask_candidates" => [] },
      "fetched_at" => (NOW - 60).iso8601
    }
    s.define_singleton_method(:utc_now) { NOW }
    req = fake_req("POST", JSON.dump({ "clear_key" => key, "mode" => "pending" }))
    res = fake_res
    s.send(:handle_needs_you_overlay, req, res)
    assert_equal 204, res.status
    stored = JSON.parse(File.read(OVERLAY_PATH))
    assert_equal "pending", stored.dig("entries", key, "mode")
    assert_equal s.send(:github_review_token, pr), stored.dig("entries", key, "token")
    assert_equal "github", stored.dig("entries", key, "source")
    refute_equal CACHE_PATH, OVERLAY_PATH

    s.instance_variable_set(:@pr_maps, {})
    s.send(:save_cache)
    cache = JSON.parse(File.read(CACHE_PATH))
    refute_includes JSON.generate(cache), key

    get = fake_req("GET", "")
    summary = fake_res
    s.send(:handle_needs_you_summary, get, summary)
    assert_equal 200, summary.status
    body = JSON.parse(summary.body)
    assert_equal 0, body.dig("tiers", "direct")
    assert_equal 1, body["pending"]
    assert_equal 0, body["snoozed"]
    %w[zz-title-route zz-login zz.example acme/widgets].each do |secret|
      refute_includes summary.body, secret
    end

    missing = fake_req("POST", JSON.dump({ "clear_key" => "github:acme/widgets#99:review", "mode" => "pending" }))
    missing_res = fake_res
    s.send(:handle_needs_you_overlay, missing, missing_res)
    assert_equal 404, missing_res.status
  end

  private

  def need(key, token, source: "github")
    {
      "kind" => "pr",
      "tier" => "direct_ask",
      "source" => source,
      "since" => (NOW - 3600).iso8601,
      "clear_key" => key,
      "change_token" => token,
      "title" => "zz-should-not-leak",
      "ask_from" => "direct"
    }
  end

  def pending(key, at: NOW - 30, source_fetched_at: NOW - 120, source: nil)
    source ||= key.split(":").first
    {
      "mode" => "pending",
      "at" => at.iso8601,
      "until" => nil,
      "token" => "oid:aaa",
      "source_fetched_at" => source_fetched_at.iso8601,
      "source" => source
    }
  end

  def avail(source, fetched:, started: nil)
    slot = { "loaded" => true, "fetched_at" => fetched.iso8601 }
    slot["refresh_started_at"] = started.iso8601 if started
    { source => slot }
  end

  def token_pr
    {
      "repo" => "acme/widgets",
      "number" => 4,
      "head_oid" => "abc",
      "latest_thread_comment_url" => "https://example.test/t/1",
      "issue_comment_url" => "https://example.test/c/1",
      "updated_at" => ago(3600, NOW),
      "title" => "Latch"
    }
  end

  def team_pr(overrides = {})
    {
      "number" => 8,
      "repo" => "acme/widgets",
      "title" => "Widget latch",
      "url" => "https://example.test/acme/widgets/8",
      "draft" => false,
      "author" => "ada",
      "direct_review" => false,
      "team_requested" => true,
      "viewer_is_author" => false,
      "labels" => ["ready"],
      "reviews_empty" => true,
      "updated_at" => ago(2 * 86_400),
      "since" => ago(2 * 86_400),
      "team_reviewers" => [{ "slug" => "platform", "name" => "Platform" }],
      "head_oid" => "abc"
    }.merge(overrides)
  end

  def direct_pr
    {
      "number" => 4,
      "repo" => "acme/widgets",
      "title" => "Latch the gate",
      "url" => "https://example.test/acme/widgets/4",
      "draft" => false,
      "author" => "ada",
      "requested_by" => "ada",
      "requested_at" => ago(3 * 3600),
      "since" => ago(3 * 3600),
      "created_at" => ago(5 * 86_400),
      "updated_at" => ago(2 * 86_400),
      "head_oid" => "abc",
      "latest_thread_comment_url" => "https://example.test/t/1",
      "issue_comment_url" => "https://example.test/c/1"
    }
  end

  def row_for_summary(tier, source, since, title, url, login, repo)
    {
      "tier" => tier,
      "source" => source,
      "since" => since.is_a?(Time) ? since.iso8601 : since,
      "title" => title,
      "action_url" => url,
      "ask_from" => login,
      "clear_key" => "github:#{repo}#1:review",
      "detail" => login
    }
  end

  def boot
    s = server
    s.instance_variable_set(:@mutex, Mutex.new)
    s.instance_variable_set(:@overlay, { "version" => 1, "entries" => {} })
    s.instance_variable_set(:@sources, {
      "local" => { "data" => nil, "fetched_at" => nil },
      "pings" => { "data" => nil, "fetched_at" => nil },
      "prs" => { "data" => nil, "fetched_at" => nil },
      "linear" => { "data" => nil, "fetched_at" => nil },
      "quota" => { "data" => nil, "fetched_at" => nil },
      "machines" => { "data" => nil, "fetched_at" => nil }
    })
    s.instance_variable_set(:@pr_maps, {})
    %i[@local_error @prs_error @quota_error @machines_error @linear_error @remote_error].each do |name|
      s.instance_variable_set(name, nil)
    end
    s
  end

  def fake_req(method, body, host: "127.0.0.1:#{BIND_PORT}")
    headers = { "Host" => host }
    Object.new.tap do |req|
      req.define_singleton_method(:request_method) { method }
      req.define_singleton_method(:body) { StringIO.new(body) }
      req.define_singleton_method(:[]) { |key| headers[key] }
    end
  end

  def fake_res
    headers = {}
    Object.new.tap do |res|
      res.instance_variable_set(:@status, nil)
      res.instance_variable_set(:@body, nil)
      res.define_singleton_method(:status) { @status }
      res.define_singleton_method(:status=) { |value| @status = value }
      res.define_singleton_method(:body) { @body }
      res.define_singleton_method(:body=) { |value| @body = value }
      res.define_singleton_method(:[]=) { |key, value| headers[key] = value }
      res.define_singleton_method(:[]) { |key| headers[key] }
    end
  end
end
