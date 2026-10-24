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

  def test_no_history_is_no_burn
    assert_equal "none", burn([])
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

  def test_muse_and_non_live_seats_never_burn
    rows = series("claude weekly all", 180, 0) { |ago| 100 - ago / 2.0 }
    assert_equal "none", burn(rows, "muse")
    assert_equal "none", burn(rows, "claude_weekly", status: "unknown")
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

  def test_drivers_name_label_and_pool_of_working_sessions_only
    srv = OpsTabServer.allocate
    sessions = [
      { "tool" => "claude", "state" => "working", "cwd" => "/home/r/secret-repo", "worktree" => "wt" },
      { "tool" => "claude", "state" => "working", "cwd" => "/x" },
      { "tool" => "codex", "state" => "idle", "cwd" => "/y" },
      { "tool" => "grok", "state" => "working", "cwd" => "/z" }
    ]
    drivers = srv.send(:burn_drivers, sessions)
    assert_equal [{ "label" => "Claude Code", "pool" => "Claude", "sessions" => 2 },
                  { "label" => "Grok CLI", "pool" => "SuperGrok", "sessions" => 1 }], drivers
    refute_match(/secret|wt|home/, JSON.dump(drivers))
    assert_equal [], srv.send(:burn_drivers, nil)
    assert_equal({ "seats" => [], "drivers" => drivers }, srv.send(:quota_with_drivers, { "seats" => [] }, sessions))
    assert_nil srv.send(:quota_with_drivers, nil, sessions)
  end
end
