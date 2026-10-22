# frozen_string_literal: true

# Needs-you tier sort, review-request age, and expiry. No network.
# The new tab draws the tiers and age badges; that is test/newtab_needs_you_test.js.
# Run: ruby test/needs_you_test.rb
require "fileutils"
require "json"
require "tmpdir"
require "time"
require "minitest/autorun"

HOME_DIR = Dir.mktmpdir("orderly-needs-you-")
ENV["HOME"] = HOME_DIR
FileUtils.mkdir_p(File.join(HOME_DIR, ".config/ops-tab"))
File.write(
  File.join(HOME_DIR, ".config/ops-tab/profile.json"),
  JSON.dump({ "viewer" => "tester" })
)
require_relative "../server"
Minitest.after_run { FileUtils.rm_rf(HOME_DIR) }

class NeedsYouTest < Minitest::Test
  def server
    OpsTabServer.allocate
  end

  def ago(seconds)
    (Time.now.utc - seconds).iso8601
  end

  def test_kind_and_reason_map_to_one_tier
    s = server
    assert_equal "direct_ask", s.send(:needs_you_tier, { "kind" => "pr" })
    assert_equal "direct_ask", s.send(:needs_you_tier, { "kind" => "pr", "reason" => "review_request" })
    assert_equal "direct_ask", s.send(:needs_you_tier, { "kind" => "pr", "reason" => "review_thread" })
    assert_equal "direct_ask", s.send(:needs_you_tier, { "kind" => "pr", "reason" => "changes_requested" })
    assert_equal "direct_ask", s.send(:needs_you_tier, { "kind" => "linear", "reason" => "linear_mention" })
    assert_equal "direct_ask", s.send(:needs_you_tier, { "kind" => "linear", "reason" => "linear_question" })
    assert_equal "blocked_on_me", s.send(:needs_you_tier, { "kind" => "pr", "reason" => "ci_failed" })
    assert_equal "blocked_on_me", s.send(:needs_you_tier, { "kind" => "agent", "reason" => "permission" })
    assert_equal "informational", s.send(:needs_you_tier, { "kind" => "agent", "reason" => "agent_exited" })
    assert_equal "informational", s.send(:needs_you_tier, { "kind" => "machine" })
    assert_equal "informational", s.send(:needs_you_tier, { "kind" => "quota", "reason" => "quota" })
    assert_equal "team_ask", s.send(:needs_you_tier, { "tier" => "team_ask" })
    assert_equal "informational", s.send(:needs_you_tier, { "kind" => "unknown" })
  end

  def test_rows_sort_by_tier_then_oldest_and_skip_team_prs
    rows = kitchen
    assert_equal %w[agent linear machine pr quota], rows.map { |r| r["kind"] }.uniq.sort
    assert_equal %w[
      direct_ask direct_ask direct_ask direct_ask direct_ask
      blocked_on_me blocked_on_me
      informational informational informational informational
    ], rows.map { |r| r["tier"] }
    assert_equal [
      "Sam asked for your review",
      "Sam asked a question in Doing",
      "1 review thread from sam with no reply",
      "sam requested changes",
      "Sam mentioned you in AB-1",
      "CI failed on the last push",
      "wt-wait is waiting on a permission prompt",
      "Box bot link disconnected",
      "Codex exhausted",
      "Process in wt-dead exited without a completed turn_ended",
      "Other bot link disconnected"
    ], rows.map { |r| r["title"] }
    refute_includes rows.map { |r| r["tier"] }, "team_ask"
    refute_includes rows.map { |r| r["detail"] }, "Team only"
  end

  def test_review_since_comes_from_the_viewers_request_event
    requested = ago(3 * 3600)
    ready = ago(5 * 3600)
    created = ago(40 * 86400)
    updated = ago(2 * 86400)
    gql = review_gql(
      created, updated,
      requests: [{ "__typename" => "User", "login" => "tester" }],
      events: [
        ready_event(ready),
        request_event(ago(10 * 86400), { "__typename" => "User", "login" => "tester" }),
        request_event(requested, { "__typename" => "User", "login" => "Tester" }),
        request_event(ago(3600), { "__typename" => "User", "login" => "other" }),
        request_event(ago(30 * 60), nil)
      ]
    )
    row = server.send(:shape_pr_row, hit(created, updated), gql, :review)
    assert_equal requested, row["since"]
    assert_equal requested, row["requested_at"]
    assert_equal ready, row["ready_at"]
    refute_equal created, row["since"]
    refute_equal updated, row["since"]

    needs = server.send(:needs_you_review, row, [])
    assert_equal 1, needs.length
    assert_equal requested, needs[0]["since"]
    assert_equal updated, needs[0]["expires_from"]
    assert_equal "review_request", needs[0]["reason"]
    assert_equal "direct_ask", server.send(:needs_you_tier, needs[0])
  end

  def test_review_since_falls_back_to_ready_then_update_then_creation
    s = server
    ready = ago(4 * 86400)
    created = ago(30 * 86400)
    updated = ago(2 * 86400)
    gql = review_gql(created, updated, requests: [{ "__typename" => "User", "login" => "tester" }], events: [ready_event(ready)])
    row = s.send(:shape_pr_row, hit(created, updated), gql, :review)
    assert_nil row["requested_at"]
    assert_equal ready, row["ready_at"]
    assert_equal ready, row["since"]

    bare = review_gql(created, updated, requests: [{ "__typename" => "User", "login" => "tester" }], events: [])
    row = s.send(:shape_pr_row, hit(created, updated), bare, :review)
    assert_equal updated, row["since"]
    assert_nil row["requested_at"]
    assert_nil row["ready_at"]

    no_update = review_gql(created, nil, requests: [{ "__typename" => "User", "login" => "tester" }], events: [])
    row = s.send(:shape_pr_row, hit(created, nil), no_update, :review)
    assert_equal created, row["since"]

    assert_equal ["2026-09-01T00:00:00Z", "review_requested"], s.send(:pick_review_since, "2026-09-01T00:00:00Z", "2026-08-01T00:00:00Z", "2026-10-01T00:00:00Z", "2026-01-01T00:00:00Z")
    assert_equal ["2026-08-01T00:00:00Z", "ready_for_review"], s.send(:pick_review_since, nil, "2026-08-01T00:00:00Z", "2026-10-01T00:00:00Z", "2026-01-01T00:00:00Z")
    assert_equal ["2026-10-01T00:00:00Z", "updated_at"], s.send(:pick_review_since, nil, nil, "2026-10-01T00:00:00Z", "2026-01-01T00:00:00Z")
    assert_equal ["2026-01-01T00:00:00Z", "created_at"], s.send(:pick_review_since, "", nil, nil, "2026-01-01T00:00:00Z")
  end

  def test_team_review_since_uses_the_team_event_and_is_not_a_needs_you_row
    created = ago(20 * 86400)
    updated = ago(86400)
    team_at = ago(3 * 86400)
    ready = ago(6 * 86400)
    gql = review_gql(
      created, updated,
      requests: [{ "__typename" => "Team", "name" => "eng", "slug" => "eng" }],
      events: [
        request_event(ago(3600), { "__typename" => "User", "login" => "other" }),
        ready_event(ready),
        request_event(team_at, { "__typename" => "Team", "name" => "eng", "slug" => "eng" })
      ]
    )
    row = server.send(:shape_pr_row, hit(created, updated), gql, :review)
    assert_equal team_at, row["since"]
    assert_equal team_at, row["requested_at"]
    built = server.send(:build_needs_you, [], { "mine" => [], "review_requested" => [], "review_requested_team" => [row] }, nil, nil, [], nil)
    assert_empty built
  end

  def test_my_prs_do_not_take_since_from_the_timeline
    created = ago(12 * 86400)
    updated = ago(86400)
    gql = review_gql(created, updated, requests: [], events: [ready_event(ago(2 * 86400))])
    row = server.send(:shape_pr_row, hit(created, updated), gql, :mine)
    assert_equal "ready", row["group"]
    assert_equal created, row["since"]
    assert_nil row["ready_at"]
  end

  def test_grace_uses_request_time_and_expiry_stays_on_last_update
    s = server
    recent = review_row(3, "recent", requested_at: ago(30 * 60), created_at: ago(10 * 86400), updated_at: ago(86400))
    assert_empty s.send(:needs_you_review, recent, [])

    ready_only = review_row(4, "just-ready", requested_at: nil, ready_at: ago(20 * 60), created_at: ago(10 * 86400), updated_at: ago(86400))
    assert_empty s.send(:needs_you_review, ready_only, [])

    from_creation = review_row(5, "old-open", requested_at: nil, ready_at: nil, since: nil, created_at: ago(10 * 86400), updated_at: ago(86400))
    shown = s.send(:needs_you_review, from_creation, [])
    assert_equal 1, shown.length
    assert_equal from_creation["created_at"], shown[0]["since"]

    stale_update = review_row(1, "quiet", requested_at: ago(3600), since: ago(3600), created_at: ago(3 * 86400), updated_at: ago(20 * 86400))
    fresh_update = review_row(2, "active", requested_at: ago(2 * 86400), since: ago(2 * 86400), created_at: ago(40 * 86400), updated_at: ago(86400))
    rows = s.send(:build_needs_you, [], { "mine" => [], "review_requested" => [stale_update, fresh_update] }, nil, nil, [], nil)
    assert_equal ["#2"], rows.map { |r| r["id"] }
    assert_equal fresh_update["since"], rows[0]["since"]
    assert_equal fresh_update["updated_at"], rows[0]["expires_from"]
    refute_equal fresh_update["created_at"], rows[0]["since"]
  end

  def test_timeline_query_is_batched_into_the_pr_selection
    assert_includes PR_GQL_FIELDS, "timelineItems(last:20, itemTypes:[REVIEW_REQUESTED_EVENT, READY_FOR_REVIEW_EVENT])"
    assert_includes PR_GQL_FIELDS, "ReviewRequestedEvent"
    assert_includes PR_GQL_FIELDS, "ReadyForReviewEvent"
  end

  private

  def kitchen
    @kitchen ||= server.send(
      :build_needs_you,
      [
        { "tool" => "claude", "state" => "waiting", "worktree" => "wt-wait", "detail" => "allow", "updated_at" => ago(2 * 3600) },
        { "tool" => "grok", "state" => "unconfirmed", "worktree" => "wt-dead", "detail" => "gone", "updated_at" => ago(12 * 3600) }
      ],
      {
        "mine" => [
          { "number" => 10, "repo" => "demo", "title" => "CI red", "ci" => "fail", "ci_failed_at" => ago(10 * 86400), "ci_failed_name" => "test", "ci_url" => "https://example.test/ci", "threads_awaiting_me" => 0, "updated_at" => ago(3600) },
          { "number" => 11, "repo" => "demo", "title" => "Threads", "ci" => "pass", "threads_awaiting_me" => 1, "threads_last_by" => "sam", "thread_comment_at" => ago(4 * 86400), "thread_comment_url" => "https://example.test/t", "updated_at" => ago(3600) },
          { "number" => 12, "repo" => "demo", "title" => "a < b & c", "ci" => "pass", "threads_awaiting_me" => 0, "review_decision" => "CHANGES_REQUESTED", "changes_requested_by" => "sam", "changes_requested_at" => ago(3 * 86400), "url" => "https://example.test/12", "updated_at" => ago(3600) }
        ],
        "review_requested" => [
          review_row(13, "Please review", requested_by: "Sam", author: "Sam", requested_at: ago(6 * 86400), since: ago(6 * 86400), created_at: ago(40 * 86400), updated_at: ago(2 * 86400))
        ],
        "review_requested_team" => [
          review_row(99, "Team only", requested_at: ago(6 * 86400), since: ago(6 * 86400), created_at: ago(20 * 86400), updated_at: ago(3600))
        ]
      },
      {
        "mentions" => [
          { "issue_id" => "AB-1", "actor" => "Sam", "kind" => "mention", "excerpt" => "hey", "at" => ago(86400), "comment_url" => "https://example.test/lin" }
        ],
        "mine" => [
          { "id" => "AB-2", "group" => "waiting", "last_comment_mine" => false, "last_comment_by" => "Sam", "last_comment_excerpt" => "thoughts?", "last_comment_at" => ago(5 * 86400), "state" => "Doing", "url" => "https://example.test/ab2", "worktrees" => [] }
        ]
      },
      { "seats" => [{ "status" => "live", "seat" => "codex", "label" => "Codex · weekly", "exhausted" => true, "text" => "none left", "verified_at" => ago(3 * 86400) }] },
      [],
      {
        "machines" => [
          { "expected_always_on" => true, "label" => "Box", "link" => "disconnected", "link_as_of" => ago(8 * 86400), "heartbeat" => "live" },
          { "expected_always_on" => true, "label" => "Other", "link" => "disconnected", "link_as_of" => nil, "heartbeat" => "live" }
        ]
      }
    )
  end

  def review_row(number, title, requested_by: "sam", author: "sam", requested_at: nil, ready_at: nil, since: nil, created_at: nil, updated_at: nil)
    {
      "number" => number,
      "repo" => "demo",
      "title" => title,
      "url" => "https://example.test/#{number}",
      "draft" => false,
      "author" => author,
      "requested_by" => requested_by,
      "requested_at" => requested_at,
      "ready_at" => ready_at,
      "since" => since,
      "created_at" => created_at,
      "updated_at" => updated_at
    }
  end

  def hit(created, updated)
    {
      "number" => 7,
      "title" => "Latch",
      "repository" => { "name" => "demo" },
      "url" => "https://example.test/7",
      "createdAt" => created,
      "updatedAt" => updated,
      "isDraft" => false,
      "author" => { "login" => "ada" }
    }
  end

  def review_gql(created, updated, requests:, events:)
    {
      "title" => "Latch",
      "url" => "https://example.test/7",
      "isDraft" => false,
      "createdAt" => created,
      "updatedAt" => updated,
      "author" => { "login" => "ada" },
      "reviewRequests" => { "nodes" => requests.map { |reviewer| { "requestedReviewer" => reviewer } } },
      "timelineItems" => { "nodes" => events }
    }
  end

  def request_event(at, reviewer)
    { "__typename" => "ReviewRequestedEvent", "createdAt" => at, "requestedReviewer" => reviewer }
  end

  def ready_event(at)
    { "__typename" => "ReadyForReviewEvent", "createdAt" => at }
  end
end
