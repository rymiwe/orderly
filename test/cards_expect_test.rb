# frozen_string_literal: true

# Expect (snapshot) tests for the /cards payload. Each directory under
# test/fixtures/cards is one state: sources.json (what each source last
# returned), and optionally seat-usage.json, history.jsonl and machines.json,
# which the quota and machines readers parse the way they do in production.
# The payload from handle_cards is compared with test/expect/cards/<case>.json.
#
# Nothing leaves the process: gh, Linear, op, seat-usage and the fleet reader
# are stubbed, the clock is frozen, and the host name is fixed. Paths under the
# temp HOME are written as $HOME. Keys are sorted.
#
# Run:            ruby test/cards_expect_test.rb
# Rewrite files:  UPDATE_EXPECT=1 ruby test/cards_expect_test.rb
require "fileutils"
require "json"
require "net/http"
require "tmpdir"
require "time"
require "minitest/autorun"

FIXTURES = File.expand_path("fixtures/cards", __dir__)
EXPECT_DIR = File.expand_path("expect/cards", __dir__)
FROZEN_NOW = Time.utc(2026, 10, 26, 12, 0, 0)

# Frozen clock. Process.clock_gettime is left alone, so timeouts still work.
module FrozenClock
  def now(*args, **kw)
    return super if args.any? || kw.any?

    FROZEN_NOW.dup
  end
end
Time.singleton_class.prepend(FrozenClock)

HOME_DIR = Dir.mktmpdir("orderly-cards-expect-")
ENV["HOME"] = HOME_DIR
ENV["GROK_BOT_FLEET_CACHE"] = File.join(HOME_DIR, ".cache/grok-bot-fleet/machines.json")
ENV["OPS_TAB_OVERLAY_PATH"] = File.join(HOME_DIR, ".local/state/ops-tab/needs-you-overlay.json")
FileUtils.mkdir_p(File.join(HOME_DIR, ".config/ops-tab"))
FileUtils.cp(File.join(FIXTURES, "profile.json"), File.join(HOME_DIR, ".config/ops-tab/profile.json"))
require_relative ENV["ORDERLY_SERVER"] || "../server"
Minitest.after_run { FileUtils.rm_rf(HOME_DIR) }

# Any command or HTTP call would make the snapshot depend on this machine.
class Object
  private

  def run_cmd(*args, **_kw)
    raise "cards expect test: unexpected command #{args.first}"
  end
end

module NoNetwork
  def new(*args, **kw)
    raise "cards expect test: unexpected HTTP to #{args.first}"
  end
end
Net::HTTP.singleton_class.prepend(NoNetwork)

class CardsExpectTest < Minitest::Test
  FakeRequest = Struct.new(:headers) do
    def [](key)
      headers[key]
    end
  end

  class FakeResponse
    attr_accessor :status, :body

    def initialize
      @headers = {}
    end

    def []=(key, value)
      @headers[key] = value
    end

    def [](key)
      @headers[key]
    end
  end

  def self.cases
    Dir.children(FIXTURES).select { |n| File.directory?(File.join(FIXTURES, n)) }.sort
  end

  cases.each do |name|
    define_method("test_cards_#{name}") { check_case(name) }
  end

  def test_fixture_cases_cover_the_required_states
    assert_equal %w[capped empty typical], self.class.cases & %w[capped empty typical]
  end

  private

  def check_case(name)
    actual = render(name)
    path = File.join(EXPECT_DIR, "#{name}.json")
    if ENV["UPDATE_EXPECT"] == "1"
      FileUtils.mkdir_p(EXPECT_DIR)
      File.write(path, actual)
      return
    end
    assert File.file?(path), "missing #{path}; run UPDATE_EXPECT=1 ruby test/cards_expect_test.rb"
    expected = File.read(path)
    return if expected == actual

    flunk("/cards for #{name} differs from test/expect/cards/#{name}.json " \
          "(UPDATE_EXPECT=1 rewrites it)\n#{diff(expected, actual)}")
  end

  def render(name)
    dir = File.join(FIXTURES, name)
    reset_home
    copy_if(dir, "seat-usage.json", SEAT_USAGE_CACHE)
    copy_if(dir, "history.jsonl", SEAT_USAGE_HISTORY)
    copy_if(dir, "machines.json", FLEET_CACHE)
    fixture = JSON.parse(File.read(File.join(dir, "sources.json")).gsub("@HOME@", HOME_DIR))
    res = FakeResponse.new
    build_server(fixture, dir).send(:handle_cards, FakeRequest.new({ "Host" => "127.0.0.1:#{BIND_PORT}" }), res)
    assert_equal 200, res.status
    "#{JSON.pretty_generate(normalize(JSON.parse(res.body)))}\n"
  end

  def build_server(fixture, dir)
    srv = OpsTabServer.allocate
    host = fixture["host_suggestion"]
    srv.define_singleton_method(:maybe_spawn_seat_usage) {}
    srv.define_singleton_method(:maybe_spawn_fleet) {}
    srv.define_singleton_method(:fetch_host_suggestion) { host }
    srv.define_singleton_method(:host_short_name) { "testhost" }
    srv.define_singleton_method(:save_overlay) {}
    srv.define_singleton_method(:save_cache) {}
    srv.instance_variable_set(:@mutex, Mutex.new)
    %i[@local_error @remote_error @prs_error @linear_error @linear_mentions_error @quota_error @machines_error].each do |ivar|
      srv.instance_variable_set(ivar, nil)
    end
    srv.instance_variable_set(:@linear_error, fixture["linear_error"]) if fixture.key?("linear_error")
    srv.instance_variable_set(:@ping_cache, {})
    srv.instance_variable_set(:@action_token, "0" * 32)
    srv.instance_variable_set(:@pr_maps, REPOS.to_h { |repo| [repo["name"], srv.send(:empty_pr_map)] })
    srv.send(:load_pr_maps, { "pr_maps" => fixture["pr_maps"] }) if fixture["pr_maps"]
    srv.send(:load_overlay)
    at = fixture["fetched_at"]
    sources = %w[local pings prs linear quota machines].to_h { |n| [n, { "data" => nil, "fetched_at" => nil }] }
    %w[local pings prs linear].each do |n|
      sources[n] = { "data" => fixture[n], "fetched_at" => at } if fixture.key?(n)
    end
    srv.instance_variable_set(:@sources, sources)
    if File.file?(File.join(dir, "seat-usage.json"))
      sources["quota"] = { "data" => srv.send(:fetch_quota), "fetched_at" => at }
    end
    if File.file?(File.join(dir, "machines.json"))
      sources["machines"] = { "data" => srv.send(:fetch_machines), "fetched_at" => at }
    end
    srv
  end

  def reset_home
    [SEAT_USAGE_CACHE, SEAT_USAGE_HISTORY, FLEET_CACHE].each { |p| FileUtils.rm_f(p) }
  end

  def copy_if(dir, file, dest)
    src = File.join(dir, file)
    return unless File.file?(src)

    FileUtils.mkdir_p(File.dirname(dest))
    FileUtils.cp(src, dest)
  end

  # Sorted keys, and the temp HOME written as $HOME so no machine path is saved.
  def normalize(value)
    case value
    when Hash then value.keys.sort.to_h { |k| [k, normalize(value[k])] }
    when Array then value.map { |v| normalize(v) }
    when String then value.gsub(HOME_DIR, "$HOME")
    else value
    end
  end

  def diff(expected, actual)
    a = expected.lines
    b = actual.lines
    out = []
    [a.size, b.size].max.times do |i|
      next if a[i] == b[i]

      out << "line #{i + 1}:"
      out << "- #{a[i]&.chomp}"
      out << "+ #{b[i]&.chomp}"
      break if out.size >= 60
    end
    out.join("\n")
  end
end
