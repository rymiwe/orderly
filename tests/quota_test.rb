# frozen_string_literal: true

# Quota payload: groups come from the cache's "seats" rows (quartermaster's
# seat_rows). Known groups keep their builders; others get a row per bar.
# No network. Run: ruby tests/quota_test.rb
require "json"
require "tmpdir"
require "time"
require "minitest/autorun"

HOME_DIR = Dir.mktmpdir("orderly-quota-")
ENV["HOME"] = HOME_DIR
require_relative ENV["ORDERLY_SERVER"] || "../server"
Minitest.after_run { FileUtils.rm_rf(HOME_DIR) }

class QuotaTest < Minitest::Test
  NOW = Time.now.to_f
  KNOWN = %w[claude_weekly claude_fable codex cursor_models cursor_other grokbot supergrok muse].freeze

  def write_cache(data)
    FileUtils.mkdir_p(File.dirname(SEAT_USAGE_CACHE))
    File.write(SEAT_USAGE_CACHE, JSON.dump({ "ts" => NOW }.merge(data)))
  end

  def seats
    srv = OpsTabServer.allocate
    srv.define_singleton_method(:maybe_spawn_seat_usage) {}
    srv.define_singleton_method(:fetch_host_suggestion) { nil }
    srv.send(:fetch_quota)["seats"]
  end

  def bar(name, pool, pct, label: nil)
    { "kind" => "seat", "name" => name, "seat" => "google", "pool" => pool, "pct" => pct,
      "reset_ts" => NOW + 86_400, "window_s" => 604_800, "label" => label }.compact
  end

  def test_a_cache_without_rows_still_lists_the_known_seats
    write_cache("claude_week" => 40)
    assert_equal KNOWN, seats.map { |s| s["seat"] }
  end

  def test_rows_set_the_order_and_add_groups_orderly_has_no_builder_for
    write_cache(
      "as_of" => { "google" => NOW, "muse" => NOW },
      "google_argon_week_pace" => "under",
      "seats" => [
        { "id" => "mu", "label" => "Muse", "bars" => [] },
        { "id" => "gg", "label" => "Google",
          "bars" => [bar("argon", "google_argon_week", 3, label: "Argon weekly").merge("families" => ["Argon"]),
                     bar("c/g", "google_claudegpt_week", nil)] },
        { "id" => "cl", "label" => "Claude", "bars" => [] }
      ]
    )
    rows = seats
    assert_equal %w[muse google_argon_week google_claudegpt_week claude_weekly claude_fable], rows.map { |s| s["seat"] }
    argon = rows[1]
    assert_equal ["Google · Argon weekly", "live", 3, "3% · under pace", "google", "google", false],
                 argon.values_at("label", "status", "percent", "text", "vendor", "subscription", "read_failed")
    assert_equal 604_800, argon["window_s"]
    assert_equal ["Google · c/g", "unknown"], rows[2].values_at("label", "status")
    assert_equal [["Argon"], []], rows[1..2].map { |r| r["families"] }
  end

  def test_a_failed_google_read_says_so
    write_cache("as_of" => {}, "errors" => { "google" => "HTTPError 500" },
                "seats" => [{ "id" => "gg", "label" => "Google",
                              "bars" => [{ "kind" => "failed", "name" => "gg", "seat" => "google" }] }])
    row = seats.first
    assert_equal ["google_gg", "unknown", true, "HTTPError 500"], row.values_at("seat", "status", "read_failed", "read_error")
  end

  # Burn level. History rows are what quartermaster's record_pool appends.
  WEEK = 604_800
  FIVE_H = 18_000

  def hist(pool, ago_min, pct, reset: NOW + 86_400, window: WEEK)
    { "host" => "BLD", "seat" => "x", "pool" => pool, "used_pct" => pct, "reset_ts" => reset,
      "window_s" => window, "source" => "test", "read_ts" => NOW - (ago_min * 60) }
  end

  # A reading every 10 minutes from `from` minutes ago to `to` minutes ago.
  def series(pool, from, to, window: WEEK, reset: NOW + 86_400)
    from.step(to, -10).map { |ago| hist(pool, ago, yield(ago), reset: reset, window: window) }
  end

  def burn(rows, seat = "claude_weekly", status: "live")
    srv = OpsTabServer.allocate
    history = rows.group_by { |r| r["pool"] }.transform_values { |l| l.sort_by { |r| r["read_ts"] } }
    srv.send(:quota_burn, history, { "seat" => seat, "status" => status }, NOW)
  end

  def pph(rows, seat = "claude_weekly")
    srv = OpsTabServer.allocate
    history = rows.group_by { |r| r["pool"] }.transform_values { |l| l.sort_by { |r| r["read_ts"] } }
    srv.send(:quota_burn_pph, history, { "seat" => seat, "status" => "live" }, NOW)
  end

  def test_no_history_is_no_burn
    assert_equal "none", burn([])
    assert_nil pph([])
  end

  def test_burn_pph_is_the_rise_over_the_last_30_minutes
    # Base is the row at 30 minutes (4 points over half an hour = 8.0).
    rows = [
      hist("claude weekly all", 40, 10),
      hist("claude weekly all", 30, 10),
      hist("claude weekly all", 0, 14)
    ]
    assert_equal 8.0, pph(rows)
  end

  def test_burn_pph_ignores_the_previous_reset
    old_reset = NOW - 1200
    rows = [
      hist("claude weekly all", 50, 90, reset: old_reset),
      hist("claude weekly all", 40, 88, reset: old_reset),
      hist("claude weekly all", 10, 2),
      hist("claude weekly all", 0, 3)
    ]
    # No same-reset row at or before 30 minutes. One point in 10 minutes,
    # divided by the full half hour, is 2.0 rather than a drop from 90.
    assert_equal 2.0, pph(rows)
    assert_equal "soft", burn(rows)
  end

  def test_burn_pph_is_nil_when_the_newest_reading_is_stale
    rows = [hist("claude weekly all", 40, 10), hist("claude weekly all", 25, 20)]
    assert_nil pph(rows)
    assert_equal "none", burn(rows)
  end

  def test_a_short_history_does_not_overstate_burn_pph
    # 10 points in 10 minutes would be 60/h if that span were trusted.
    rows = [hist("claude weekly all", 10, 10), hist("claude weekly all", 0, 20)]
    assert_equal 20.0, pph(rows)
  end

  def test_burn_pph_clamps_a_fall_at_zero
    rows = [hist("claude weekly all", 30, 50), hist("claude weekly all", 0, 40)]
    assert_equal 0.0, pph(rows)
    assert_equal "none", burn(rows)
  end

  def test_burn_pph_rounds_to_one_decimal_and_takes_the_faster_pool
    weekly = [hist("claude weekly all", 30, 10), hist("claude weekly all", 0, 12)]
    five = [
      hist("claude 5h", 30, 10, window: FIVE_H),
      hist("claude 5h", 0, 14.14, window: FIVE_H)
    ]
    assert_equal 4.0, pph(weekly)
    # 4.14 points in half an hour is 8.28, which rounds to 8.3, and wins.
    assert_equal 8.3, pph(weekly + five)
  end

  def test_a_move_in_the_last_30_minutes_is_soft
    # Two points on the 5h pool, well under its 20-points-an-hour pace.
    rows = series("claude 5h", 180, 0, window: FIVE_H) { |ago| ago > 20 ? 10 : 12 }
    assert_equal "soft", burn(rows)
  end

  def test_a_rise_of_at_least_one_pace_over_two_hours_is_strong
    # 5h pace is 20 points an hour; this rises 45 points in two hours.
    rows = series("claude 5h", 180, 0, window: FIVE_H) { |ago| ago >= 120 ? 10 : 10 + ((120 - ago) * 45 / 120.0) }
    assert_equal "strong", burn(rows)
  end

  def test_a_reset_inside_the_window_is_not_a_move
    old = series("claude weekly all", 180, 30, reset: NOW - 1200) { 90 }
    fresh = series("claude weekly all", 20, 0) { 2 }
    assert_equal "none", burn(old + fresh)
  end

  def test_a_newest_reading_older_than_20_minutes_is_no_burn
    rows = series("claude weekly all", 180, 25) { |ago| ago > 40 ? 40 : 50 }
    assert_equal "none", burn(rows)
  end

  def test_a_one_point_step_on_a_weekly_pool_is_soft_not_strong
    rows = series("chatgpt weekly", 180, 0) { |ago| ago > 5 ? 40 : 41 }
    assert_equal "soft", burn(rows, "codex")
  end

  def test_the_5h_level_wins_over_a_flat_weekly
    weekly = series("claude weekly all", 180, 0) { 40 }
    five = series("claude 5h", 180, 0, window: FIVE_H) { |ago| ago >= 120 ? 10 : 60 - (ago / 3.0) }
    assert_equal "none", burn(weekly)
    assert_equal "strong", burn(weekly + five)
  end

  def muse_row
    seats.find { |s| s["seat"] == "muse" }
  end

  def test_an_exhausted_muse_quota_with_a_future_reset_is_out_of_usage
    reset = NOW + 3 * 3600
    write_cache("as_of" => { "muse" => NOW },
                "muse_exhausted" => true,
                "muse_exhausted_reset_ts" => reset)
    row = muse_row
    assert_equal ["live", 100, "out of usage", true, false],
                 row.values_at("status", "percent", "text", "exhausted", "read_failed")
    assert_equal iso(Time.at(reset)), row["resets_at"]
    assert_equal WEEK_S, row["window_s"]
    assert_nil row["note"]
    assert_nil row["five_hour"]
  end

  def test_an_exhausted_muse_quota_outranks_a_carried_percent
    write_cache("as_of" => { "muse" => NOW },
                "muse_exhausted" => true,
                "muse_exhausted_reset_ts" => NOW + 3600,
                "muse_week" => 40, "muse_5h" => 12)
    row = muse_row
    assert_equal ["out of usage", 100, true], row.values_at("text", "percent", "exhausted")
    assert_nil row["five_hour"]
  end

  def test_muse_falls_back_once_the_quota_reset_has_passed
    write_cache("as_of" => { "muse" => NOW },
                "muse_exhausted" => true,
                "muse_exhausted_reset_ts" => NOW - 60)
    row = muse_row
    assert_equal ["unknown", "unknown", "seat-usage has no value"], row.values_at("status", "text", "note")
    assert_nil row["exhausted"]

    write_cache("as_of" => { "muse" => NOW },
                "muse_exhausted" => true,
                "muse_exhausted_reset_ts" => NOW - 60,
                "muse_week" => 18, "muse_5h" => 4)
    row = muse_row
    assert_equal ["live", 18, "18% · 5h 4%"], row.values_at("status", "percent", "text")
    assert_nil row["exhausted"]
    assert_equal 4, row["five_hour"]["percent"]
  end

  def test_a_muse_flag_without_a_future_reset_is_not_out_of_usage
    write_cache("as_of" => { "muse" => NOW }, "muse_exhausted" => true, "muse_week" => 22)
    row = muse_row
    assert_equal ["live", 22, "22%"], row.values_at("status", "percent", "text")
    assert_nil row["exhausted"]

    write_cache("as_of" => { "muse" => NOW }, "muse_exhausted" => "yes",
                "muse_exhausted_reset_ts" => NOW + 3600, "muse_week" => 22)
    row = muse_row
    assert_equal "22%", row["text"]
    assert_nil row["exhausted"]
  end

  def test_a_normal_muse_percent_is_unchanged
    write_cache("as_of" => { "muse" => NOW }, "muse_week" => 18, "muse_5h" => 4)
    row = muse_row
    assert_equal ["live", 18, "18% · 5h 4%"], row.values_at("status", "percent", "text")
    assert_nil row["exhausted"]
    assert_equal WEEK_S, row["window_s"]
  end

  def test_muse_does_not_burn_from_another_seats_pool
    rows = series("claude weekly all", 180, 0) { |ago| 100 - ago / 2.0 }
    assert_equal "none", burn(rows, "muse")
    assert_equal "none", burn(rows, "claude_weekly", status: "unknown")
  end

  # muse 5h / muse weekly and chatgpt 5h are the rows seat-usage appends.
  def test_muse_and_codex_5h_go_soft_and_strong_from_their_history_rows
    muse_soft = series("muse 5h", 180, 0, window: FIVE_H) { |ago| ago > 20 ? 10 : 12 }
    assert_equal "soft", burn(muse_soft, "muse")
    muse_strong = series("muse weekly", 180, 0) { |ago| ago >= 120 ? 10 : 10 + ((120 - ago) * 45 / 120.0) }
    assert_equal "strong", burn(muse_strong, "muse")
    weekly = series("chatgpt weekly", 180, 0) { 40 }
    codex_soft = series("chatgpt 5h", 180, 0, window: FIVE_H) { |ago| ago > 20 ? 10 : 12 }
    codex_strong = series("chatgpt 5h", 180, 0, window: FIVE_H) { |ago| ago >= 120 ? 10 : 10 + ((120 - ago) * 45 / 120.0) }
    assert_equal "none", burn(weekly, "codex")
    assert_equal "soft", burn(weekly + codex_soft, "codex")
    assert_equal "strong", burn(weekly + codex_strong, "codex")
  end

  def test_fetch_quota_burns_muse_and_codex_from_those_history_rows
    write_cache("as_of" => { "muse" => NOW, "chatgpt" => NOW },
                "muse_week" => 35, "muse_5h" => 12,
                "codex" => 40, "codex_5h" => 12, "codex_window_s" => WEEK)
    rows = series("muse 5h", 180, 0, window: FIVE_H) { |ago| ago > 20 ? 10 : 12 }
    rows += series("chatgpt 5h", 180, 0, window: FIVE_H) { |ago| ago >= 120 ? 10 : 10 + ((120 - ago) * 45 / 120.0) }
    FileUtils.mkdir_p(File.dirname(SEAT_USAGE_HISTORY))
    File.write(SEAT_USAGE_HISTORY, rows.map { |r| JSON.dump(r) }.join("\n") + "\n")
    by_seat = seats.to_h { |s| [s["seat"], s["burn"]] }
    by_pph = seats.to_h { |s| [s["seat"], s["burn_pph"]] }
    assert_equal "soft", by_seat["muse"]
    assert_equal "strong", by_seat["codex"]
    # muse 5h: 10 → 12 over the last 30 minutes = 4.0. codex 5h rises faster.
    assert_equal 4.0, by_pph["muse"]
    assert_equal 22.5, by_pph["codex"]
    assert_nil by_pph["claude_weekly"]
    assert_equal "live", seats.find { |s| s["seat"] == "muse" }["status"]
  ensure
    FileUtils.rm_f(SEAT_USAGE_HISTORY)
  end

  def test_google_rows_read_their_pool_from_the_seat_id
    rows = series("google Gemini 5h", 180, 0, window: FIVE_H) { |ago| ago > 20 ? 5 : 7 }
    assert_equal "soft", burn(rows, "google_gemini_5h")
    assert_equal "none", burn(rows, "google_gemini_week")
  end

  def test_fetch_quota_reads_the_history_file_and_tolerates_junk
    write_cache("as_of" => { "claude" => NOW }, "claude_week" => 42, "claude_5h" => 12, "claude_tier" => "default_claude_max_20x")
    rows = series("claude 5h", 180, 0, window: FIVE_H) { |ago| ago > 20 ? 10 : 12 }
    FileUtils.mkdir_p(File.dirname(SEAT_USAGE_HISTORY))
    File.write(SEAT_USAGE_HISTORY, "not json\n" + rows.map { |r| JSON.dump(r) }.join("\n") + "\n{\"pool\":7}\n")
    by_seat = seats.to_h { |s| [s["seat"], s["burn"]] }
    assert_equal "soft", by_seat["claude_weekly"]
    assert_equal "none", by_seat["muse"]
  ensure
    FileUtils.rm_f(SEAT_USAGE_HISTORY)
  end

  def test_users_map_working_sessions_onto_seats_and_strip_paths
    srv = OpsTabServer.allocate
    started = "2026-10-25T20:00:00Z"
    home_chair = File.join(HOME, "code/conclave/tmp/chairs/box-chair")
    home_council = File.join(HOME, "code/conclave/tmp/council/nightly-review/notes")
    claude = { "seat" => "claude_weekly", "label" => "Claude" }
    sessions = [
      { "tool" => "claude", "state" => "working", "id" => "sess-secret",
        "cwd" => "/home/r/secret-repo", "worktree" => "wt-secret",
        "started_at" => started, "resume_command" => "claude --resume sess-secret" },
      { "tool" => "claude", "state" => "working", "id" => "sess-chair",
        "cwd" => "/workspace/conclave/tmp/chairs/muse-exhausted/src",
        "worktree" => "wt-chair", "started_at" => started },
      { "tool" => "claude", "state" => "working", "cwd" => home_chair, "started_at" => started },
      { "tool" => "claude", "state" => "idle", "cwd" => "/workspace/conclave/tmp/chairs/not-working" },
      { "tool" => "claude", "state" => "working", "id" => "escaped",
        "cwd" => "/workspace/conclave/tmp/chairs/../not-a-chair" },
      { "tool" => "codex", "state" => "working", "id" => "cx-1",
        "cwd" => home_council, "worktree" => "wt-council", "started_at" => started },
      { "tool" => "codex", "state" => "working", "cwd" => "/tmp/plain-codex",
        "started_at" => "/tmp/secret-started" },
      { "tool" => "grok", "state" => "working", "id" => "gk-1",
        "cwd" => "/workspace/conclave/tmp/council/routing-check",
        "worktree" => "wt-grok", "started_at" => started },
      { "tool" => "grok", "state" => "waiting", "cwd" => "/workspace/conclave/tmp/chairs/waiting-chair" },
      { "tool" => "cursor", "state" => "working", "cwd" => "/workspace/conclave/tmp/chairs/cursor-chair" }
    ]
    quota = {
      "drivers" => [{ "label" => "Claude Code", "pool" => "Claude", "sessions" => 9 }],
      "seats" => [
        claude,
        { "seat" => "codex" },
        { "seat" => "cursor_models" },
        { "seat" => "supergrok" }
      ]
    }
    out = srv.send(:quota_with_users, quota, sessions)
    machine = Socket.gethostname.to_s.split(".", 2).first
    users = out["seats"].to_h { |s| [s["seat"], s["users"]] }
    assert_equal [
      { "label" => "Claude Code", "machine" => machine, "started_at" => started },
      { "label" => "Chair: muse-exhausted", "machine" => machine, "started_at" => started },
      { "label" => "Chair: box-chair", "machine" => machine, "started_at" => started },
      { "label" => "Claude Code", "machine" => machine }
    ], users["claude_weekly"]
    assert_equal [
      { "label" => "Council: nightly-review", "machine" => machine, "started_at" => started },
      { "label" => "Codex", "machine" => machine }
    ], users["codex"]
    assert_equal [
      { "label" => "Council: routing-check", "machine" => machine, "started_at" => started }
    ], users["supergrok"]
    assert_equal [], users["cursor_models"]
    refute out.key?("drivers")
    refute claude.key?("users")
    dumped = JSON.dump(out)
    refute_match(%r{secret|wt-|sess-|home/r|resume|not-working|not-a-chair|escaped|notes|waiting-chair|cursor-chair|plain-codex|secret-started}, dumped)
    assert_nil srv.send(:quota_with_users, nil, sessions)
    assert_equal({ "seats" => [] }, srv.send(:quota_with_users, { "seats" => [], "drivers" => [{ "label" => "x" }] }, nil))
    assert_equal [], srv.send(:quota_with_users, { "seats" => [{ "seat" => "codex" }] }, nil)["seats"][0]["users"]
  end
end
