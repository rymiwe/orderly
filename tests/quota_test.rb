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
end
