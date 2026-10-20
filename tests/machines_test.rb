# frozen_string_literal: true

# Machines payload: heartbeat and the needs-you link rule stay; nothing feeds a
# link indicator on the card. No network. Run: ruby tests/machines_test.rb
require "json"
require "tmpdir"
require "time"
require "minitest/autorun"

HOME_DIR = Dir.mktmpdir("orderly-machines-")
ENV["HOME"] = HOME_DIR
ENV["GROK_BOT_FLEET_CACHE"] = File.join(HOME_DIR, ".cache/grok-bot-fleet/machines.json")
FileUtils.mkdir_p(File.join(HOME_DIR, ".config/ops-tab"))
File.write(File.join(HOME_DIR, ".config/ops-tab/profile.json"),
           JSON.dump({ "fleet_expected" => [{ "id" => "surface", "label" => "Surface" }, { "id" => "BLD", "label" => "BLD" }] }))
require_relative ENV["ORDERLY_SERVER"] || "../server"
Minitest.after_run { FileUtils.rm_rf(HOME_DIR) }

class MachinesTest < Minitest::Test
  def write_cache(machines)
    FileUtils.mkdir_p(File.dirname(FLEET_CACHE))
    File.write(FLEET_CACHE, JSON.dump({ "v" => 1, "as_of" => Time.now.utc.iso8601, "machines" => machines }))
  end

  def server
    OpsTabServer.allocate
  end

  def ago(seconds)
    (Time.now.utc - seconds).iso8601
  end

  def test_payload_has_no_link_indicator_fields
    write_cache([{ "id" => "surface", "link" => "unknown", "heartbeat_last" => ago(60) }])
    data = server.send(:fetch_machines)
    refute data.key?("bot_pool_empty"), data.keys.inspect
    data["machines"].each { |m| refute m.key?("link_stale"), m.inspect }
    surface = data["machines"].find { |m| m["id"] == "surface" }
    assert_equal "live", surface["heartbeat"]
    assert_operator surface["heartbeat_age_s"], :<, 120
  end

  def test_needs_you_still_uses_the_link
    write_cache([
      { "id" => "surface", "link" => "disconnected", "link_as_of" => ago(60), "heartbeat_last" => ago(60) },
      { "id" => "BLD", "link" => "connected", "link_as_of" => ago(31 * 60), "heartbeat_last" => ago(20 * 60) }
    ])
    s = server
    data = s.send(:fetch_machines)
    by = data["machines"].to_h { |m| [m["id"], m] }
    assert_equal "disconnected", by["surface"]["link"]
    assert_equal "unknown", by["BLD"]["link"] # stale link
    titles = s.send(:needs_you_from_machines, data).map { |r| r["title"] }
    assert_includes titles, "Surface bot link disconnected"
    assert_includes titles, "BLD heartbeat stale, bot link unknown"
  end
end
