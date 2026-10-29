# frozen_string_literal: true

# PR refresh against a fake gh: batching, the one gateway retry, and what the
# card serves when GitHub keeps failing. No network.
# Run: ruby test/pr_refresh_test.rb
require "fileutils"
require "json"
require "tmpdir"
require "time"
require "minitest/autorun"

HOME_DIR = Dir.mktmpdir("orderly-pr-refresh-")
ENV["HOME"] = HOME_DIR
FileUtils.mkdir_p(File.join(HOME_DIR, ".config/ops-tab"))
File.write(File.join(HOME_DIR, ".config/ops-tab/profile.json"), JSON.dump({ "viewer" => "tester" }))
require_relative "../server"
Minitest.after_run { FileUtils.rm_rf(HOME_DIR) }

class PrRefreshTest < Minitest::Test
  Status = Struct.new(:ok) do
    def success? = ok
  end

  # Answers gh the way GitHub did: `graphql` is a list of outcomes, one per
  # call, each :ok or a stderr string. The last outcome repeats.
  class FakeGh
    attr_reader :calls, :sleeps

    def initialize(hits:, graphql:, search_err: nil)
      @hits = hits
      @graphql = graphql
      @search_err = search_err
      @calls = []
      @sleeps = []
    end

    def run(args, stdin_data)
      @calls << args
      if args[1] == "search"
        return ["", @search_err, Status.new(false)] if @search_err

        mine = args[3] == "--author=@me"
        return [JSON.generate(mine ? @hits : []), "", Status.new(true)]
      end
      outcome = @graphql.size > 1 ? @graphql.shift : @graphql.first
      return ["", outcome, Status.new(false)] unless outcome == :ok

      query = JSON.parse(stdin_data)["query"]
      data = query.scan(/(pr\d+): repository\(owner:"[^"]+", name:"[^"]+"\)\{ pullRequest\(number: (\d+)\)/)
                  .to_h { |al, num| [al, { "pullRequest" => { "number" => num.to_i, "title" => "gql #{num}" } }] }
      [JSON.generate({ "data" => data }), "", Status.new(true)]
    end

    def graphql_calls = @calls.count { |a| a[1] == "api" }
  end

  def hits(count)
    (1..count).map do |n|
      { "number" => n, "title" => "search #{n}", "url" => "https://github.com/o/r/pull/#{n}",
        "repository" => { "name" => "r", "nameWithOwner" => "o/r" }, "updatedAt" => "2026-10-28T00:00:00Z" }
    end
  end

  def server_with(gh)
    s = OpsTabServer.allocate
    s.define_singleton_method(:run_cmd) { |*args, timeout: 15, chdir: nil, stdin_data: nil| gh.run(args, stdin_data) }
    s.define_singleton_method(:sleep) { |secs| gh.sleeps << secs }
    s.define_singleton_method(:warn) { |*| nil }
    s
  end

  def refreshable(gh, prs_source)
    s = server_with(gh)
    s.instance_variable_set(:@mutex, Mutex.new)
    s.instance_variable_set(:@pr_maps, {})
    s.instance_variable_set(:@sources, {
      "local" => s.send(:empty_source), "pings" => s.send(:empty_source), "prs" => prs_source,
      "linear" => s.send(:empty_source), "quota" => s.send(:empty_source), "machines" => s.send(:empty_source)
    })
    s.define_singleton_method(:fetch_linear) { raise NO_LINEAR_KEY }
    s.define_singleton_method(:fetch_quota) { raise "quota off in test" }
    s
  end

  def test_many_prs_are_fetched_in_small_queries_and_every_row_gets_its_details
    gh = FakeGh.new(hits: hits(45), graphql: [:ok])
    data = server_with(gh).send(:fetch_prs)
    assert_equal 3, gh.graphql_calls
    assert_equal 45, data["mine"].size
    assert(data["mine"].all? { |r| r["details"] == "ok" && r["title"] == "gql #{r["number"]}" })
  end

  def test_a_504_is_retried_once_after_a_short_wait
    gh = FakeGh.new(hits: hits(3), graphql: ["gh: HTTP 504", :ok])
    data = server_with(gh).send(:fetch_prs)
    assert_equal 2, gh.graphql_calls
    assert_equal [GH_RETRY_DELAY], gh.sleeps
    assert_equal %w[ok ok ok], data["mine"].map { |r| r["details"] }
  end

  def test_an_empty_gateway_body_is_retried_like_a_502
    gh = FakeGh.new(hits: hits(1), graphql: ["unexpected end of JSON input", :ok])
    assert_equal "ok", server_with(gh).send(:fetch_prs)["mine"][0]["details"]
    assert_equal 2, gh.graphql_calls
  end

  def test_a_second_gateway_failure_fails_the_refresh_without_a_third_try
    gh = FakeGh.new(hits: hits(1), graphql: ["gh: HTTP 502"])
    err = assert_raises(RuntimeError) { server_with(gh).send(:fetch_prs) }
    assert_equal "gh api graphql: gh: HTTP 502", err.message
    assert_equal 2, gh.graphql_calls
  end

  def test_other_gh_errors_are_not_retried
    gh = FakeGh.new(hits: hits(1), graphql: ["GraphQL: Could not resolve to a Repository"])
    assert_raises(RuntimeError) { server_with(gh).send(:fetch_prs) }
    assert_equal 1, gh.graphql_calls
    assert_empty gh.sleeps
  end

  def test_a_search_504_is_retried_once
    gh = FakeGh.new(hits: hits(1), graphql: [:ok], search_err: "gh: HTTP 504")
    err = assert_raises(RuntimeError) { server_with(gh).send(:fetch_prs) }
    assert_equal "gh search prs --author=@me: gh: HTTP 504", err.message
    assert_equal 2, gh.calls.size
  end

  def test_failed_refresh_keeps_the_last_good_prs_and_says_they_are_stale
    last_good = { "mine" => [{ "number" => 7, "title" => "kept" }], "review_requested" => [] }
    old_at = "2026-10-28T01:00:00Z"
    gh = FakeGh.new(hits: hits(2), graphql: ["gh: HTTP 504"])
    s = refreshable(gh, { "data" => last_good, "fetched_at" => old_at })
    s.send(:refresh_remote)
    card = s.send(:compose_cards)["prs"]
    assert_equal last_good, card["data"]
    assert_equal old_at, card["fetched_at"]
    assert_equal "gh api graphql: gh: HTTP 504", card["error"]
  end

  def test_refresh_after_a_failure_clears_the_error
    gh = FakeGh.new(hits: hits(2), graphql: ["gh: HTTP 504", "gh: HTTP 504", :ok])
    s = refreshable(gh, { "data" => { "mine" => [] }, "fetched_at" => "2026-10-28T01:00:00Z" })
    s.send(:refresh_remote)
    s.send(:refresh_remote)
    card = s.send(:compose_cards)["prs"]
    assert_nil card["error"]
    assert_equal 2, card["data"]["mine"].size
  end
end
