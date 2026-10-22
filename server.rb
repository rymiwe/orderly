#!/usr/bin/env ruby
# frozen_string_literal: true

require "cgi"
require "date"
require "fileutils"
require "json"
require "net/http"
require "open3"
require "time"
require "uri"
require "webrick"

HOME = File.expand_path("~")
ENV_PATH = File.join(HOME, ".config/ops-tab/env")
PROFILE_PATH = File.join(HOME, ".config/ops-tab/profile.json")

# The env file has to be read before any constant derived from ENV. It used to
# load in the constructor, which is after BIND_PORT was already frozen at the
# default, so OPS_TAB_PORT set only in the env file was silently ignored on the
# documented `ruby server.rb` launch.
def load_env_file
  return unless File.file?(ENV_PATH)

  File.readlines(ENV_PATH, chomp: true).each do |line|
    line = line.strip
    next if line.empty? || line.start_with?("#")

    key, value = line.split("=", 2)
    next if key.nil? || value.nil?

    key = key.strip
    ENV[key] = value.strip unless ENV.key?(key) && !ENV[key].to_s.empty?
  end
end

load_env_file

# Machine and workplace facts live in dotfiles, not in this repo. A missing
# file leaves the cards empty rather than baking one workplace in.
def read_profile
  unless File.file?(PROFILE_PATH)
    warn "ops-tab profile: no #{PROFILE_PATH}"
    return {}
  end

  parsed = JSON.parse(File.read(PROFILE_PATH))
  unless parsed.is_a?(Hash)
    warn "ops-tab profile: #{PROFILE_PATH} is not an object"
    return {}
  end

  parsed
rescue JSON::ParserError => e
  warn "ops-tab profile: #{e.message}"
  {}
end

def profile_list(profile, key)
  value = profile[key]
  value.is_a?(Array) ? value : []
end

PROFILE = read_profile.freeze

BIND_HOST = "127.0.0.1"
BIND_PORT = Integer(ENV.fetch("OPS_TAB_PORT", "5180"))
ALLOWED_HOSTS = ["127.0.0.1", "localhost", "::1"].freeze
CACHE_PATH = File.join(HOME, ".local/state/ops-tab/cache.json")
# The SuperGrok probe runs here so its sessions never look like agent work.
GROK_PROBE_DIR = File.join(HOME, ".local/state/ops-tab/grok-probe")
GROK_IGNORED_CWDS = [GROK_PROBE_DIR, "/tmp"].freeze
GROK_UUID_RE = /\h{8}-\h{4}-\h{4}-\h{4}-\h{12}/
LOCAL_INTERVAL = 5
REMOTE_INTERVAL = 120
SEAT_USAGE_DIR = File.join(HOME, ".cache/seat-usage")
SEAT_USAGE_CACHE = File.join(SEAT_USAGE_DIR, "latest.json")
SEAT_USAGE_LOCK = File.join(SEAT_USAGE_DIR, ".lock")
SEAT_USAGE_BIN = File.join(HOME, ".local/bin/seat-usage")
SEAT_USAGE_STALE = 600
SEAT_USAGE_TIMEOUT = 90
# Machine availability is a different cache from seat-usage. grokbot in the
# quota card stays the Bot's weekly allowance. Link state is never inferred
# from the host heartbeat.
FLEET_CACHE = ENV["GROK_BOT_FLEET_CACHE"] || File.join(HOME, ".cache/grok-bot-fleet/machines.json")
FLEET_DIR = File.dirname(FLEET_CACHE)
FLEET_LOCK = File.join(FLEET_DIR, ".lock")
FLEET_BIN = File.join(HOME, ".local/bin/grok-bot-machines")
FLEET_STALE = 120
FLEET_TIMEOUT = 15
# A heartbeat younger than this is live (two missed 5-minute beats).
HEARTBEAT_LIVE_S = 12 * 60
# A bot link older than this is shown as unknown. Heartbeat does not refresh it.
LINK_FRESH_S = 30 * 60
FLEET_EXPECTED = profile_list(PROFILE, "fleet_expected").filter_map { |row|
  next unless row.is_a?(Hash)

  id = row["id"].to_s
  next if id.empty?

  label = row["label"].to_s
  { "id" => id, "label" => label.empty? ? id : label }
}.freeze
PING_INTERVAL = 30
PING_TIMEOUT = 2
PRUNE_AFTER = 14 * 24 * 60 * 60
GROK_MAX_AGE = 7 * 24 * 60 * 60
GROK_NEEDS_YOU_MAX_AGE = 24 * 60 * 60
NEEDS_YOU_PR_MAX_AGE = 14 * 24 * 60 * 60
# Highest priority first. Age only orders rows inside a tier. A team-ask row
# uses reason "team_ask" so it lands in that tier; the PR card's own team
# group is a different list and stays capped at 15.
NEEDS_YOU_TIER_ORDER = %w[direct_ask blocked_on_me team_ask informational].freeze
NEEDS_YOU_TIER_LABEL = {
  "direct_ask" => "Direct ask",
  "blocked_on_me" => "Blocked on me",
  "team_ask" => "Team ask",
  "informational" => "Informational"
}.freeze
# Every needs-you `kind` maps here. A reason overrides the kind when one kind
# mixes a person asking you with something that is not an ask.
NEEDS_YOU_KIND_TIER = {
  "pr" => "direct_ask",
  "linear" => "direct_ask",
  "agent" => "blocked_on_me",
  "machine" => "informational",
  "quota" => "informational"
}.freeze
NEEDS_YOU_REASON_TIER = {
  "ci_failed" => "blocked_on_me",
  "agent_exited" => "informational",
  "team_ask" => "team_ask"
}.freeze
# Summary keys are the short names from the design packet. Row `tier` stays
# the longer id this page already renders.
SUMMARY_TIER_KEY = {
  "direct_ask" => "direct",
  "blocked_on_me" => "blocked",
  "team_ask" => "team",
  "informational" => "info"
}.freeze
SUMMARY_SOURCES = %w[github linear agent quota machine slack].freeze
CODEX_WORKING_MTIME = 120
TAIL_BYTES = 16_384
# Ceiling for re-reading when a single JSONL record is larger than the window.
MAX_TAIL_BYTES = 4 * 1024 * 1024
REPOS = profile_list(PROFILE, "repos").filter_map { |row|
  next unless row.is_a?(Hash)

  name = row["name"].to_s
  root = row["root"].to_s
  next if name.empty? || root.empty?

  pings = row["pings"].is_a?(Array) ? row["pings"].map(&:to_s).reject(&:empty?) : []
  pings = %w[/login] if pings.empty?
  port = row["db_port"]
  {
    "name" => name,
    "root" => File.expand_path(root),
    "db_port" => port.is_a?(Numeric) ? port.to_i : nil,
    "pings" => pings.freeze
  }
}.freeze
PING_PATHS = REPOS.to_h { |repo| [repo["name"], repo["pings"]] }.freeze
# Postgres for each profiled repo, plus the default Postgres port, Redis, and
# this server. Those listeners are not app servers.
EXCLUDED_PORTS = ([5432, 6379, BIND_PORT] + REPOS.filter_map { |repo| repo["db_port"] }).uniq.freeze
# Same order as the Claude Code status line: claude, codex, cursor (with the
# Bot, which Cursor bills), grok, muse.
QUOTA_SEATS = [
  { "seat" => "claude_weekly", "label" => "Claude · weekly", "action" => "/usage" },
  { "seat" => "claude_fable", "label" => "Claude · Fable slice", "action" => "/usage" },
  { "seat" => "codex", "label" => "Codex · weekly", "action" => "codex" },
  { "seat" => "cursor_models", "label" => "Cursor · Cursor Models", "action" => "cursor-agent" },
  { "seat" => "cursor_other", "label" => "Cursor · Other Models", "action" => "cursor-agent" },
  { "seat" => "grokbot", "label" => "Grok Bot · weekly", "action" => "Grok Bot" },
  { "seat" => "supergrok", "label" => "SuperGrok · weekly", "action" => "grok" },
  { "seat" => "muse", "label" => "Muse · weekly", "action" => "muse" }
].freeze
WEEK_S = 7 * 24 * 60 * 60
QUOTA_NEEDS_YOU_AT = 80
ME_LOGIN = PROFILE["viewer"].to_s.downcase
GITHUB_ORG = PROFILE["github_org"].to_s
OPX = PROFILE["op_bin"].to_s.empty? ? "op" : PROFILE["op_bin"].to_s
LINEAR_OP_REF = PROFILE["linear_op_ref"].to_s
LINEAR_URL = "https://api.linear.app/graphql"
NO_LINEAR_KEY = "no key in 1Password"
OP_RATE_LIMIT_BACKOFF = 30 * 60
WAITING_STATES = profile_list(PROFILE, "waiting_states").map(&:to_s).freeze
NEXT_UP_LABEL = PROFILE["next_up_label"].to_s
PROFILE_VIEW = {
  "brand" => PROFILE["brand"].to_s,
  "viewer" => ME_LOGIN,
  "search_placeholder" => PROFILE["search_placeholder"].to_s,
  "next_up_label" => NEXT_UP_LABEL,
  "repos" => REPOS.map { |repo| repo["name"] }
}.freeze
SEARCH_LIMIT = 100
REVIEW_KEEP_LIMIT = 30
REVIEW_TEAM_KEEP_LIMIT = 15
REVIEW_REQUEST_GRACE = 3600
REVIEW_RECENT_WINDOW = 7 * 24 * 60 * 60
# Team-ask staleness. Not REVIEW_RECENT_WINDOW: that one is the "reviewed by
# me" lookback subtracted from updated_at.
TEAM_ASK_MAX_AGE = 7 * 24 * 60 * 60
PENDING_TTL = 15 * 60
UNTIL_CHANGE_BACKSTOP = 14 * 24 * 60 * 60
SNOOZE_UNTIL_MAX = 30 * 24 * 60 * 60
# One overlay file on this machine. Not the repo, and not cache.json.
# Tests point OPS_TAB_OVERLAY_PATH at a temp file.
OVERLAY_PATH = ENV["OPS_TAB_OVERLAY_PATH"] || File.join(HOME, ".local/state/ops-tab/needs-you-overlay.json")
OVERLAY_BODY_MAX = 16_384
# Adapter source id -> snapshot key in @sources. slack has no producer.
NEEDS_YOU_SNAPSHOT = {
  "github" => "prs",
  "linear" => "linear",
  "agent" => "local",
  "quota" => "quota",
  "machine" => "machines",
  "slack" => "slack"
}.freeze
BOT_AUTHOR_LOGINS = %w[dependabot dependabot[bot] renovate].freeze
CHECK_FAIL_CONCLUSIONS = %w[FAILURE TIMED_OUT STARTUP_FAILURE ACTION_REQUIRED].freeze
STATUS_FAIL_STATES = %w[FAILURE ERROR].freeze
PR_GQL_FIELDS = <<-'GQL'.freeze
      number
      title
      url
      isDraft
      updatedAt
      createdAt
      reviewDecision
      author { login }
      commits(last:1){nodes{commit{oid statusCheckRollup{state contexts(first:50){nodes{... on CheckRun{name conclusion completedAt detailsUrl} ... on StatusContext{context state targetUrl}}}}}}}
      labels(first:10){nodes{name}}
      comments(last:1){nodes{url}}
      reviewThreads(first:50){nodes{isResolved comments(last:1){nodes{author{login} createdAt url}}}}
      latestReviews(first:20){nodes{author{login} state submittedAt}}
      reviewRequests(first:10){nodes{requestedReviewer{__typename ... on User{login} ... on Team{name slug}}}}
      timelineItems(last:20, itemTypes:[REVIEW_REQUESTED_EVENT, READY_FOR_REVIEW_EVENT]){nodes{__typename ... on ReviewRequestedEvent{createdAt requestedReviewer{__typename ... on User{login} ... on Team{name slug}}} ... on ReadyForReviewEvent{createdAt}}}
GQL
LINEAR_QUERY = <<-'GQL'.freeze
{ viewer { id name
  assignedIssues(first: 100, filter: { state: { type: { nin: ["completed", "canceled"] } } }) {
    nodes { id identifier title url priority updatedAt createdAt
      state { name type } team { key } labels { nodes { name } }
      comments(last: 1) { nodes { createdAt body user { id name displayName } } } } } } }
GQL
LINEAR_NOTIF_QUERY = <<-'GQL'.freeze
{ viewer { id }
  notifications(first: 50) { nodes { id type createdAt
    ... on IssueNotification {
      issue { id identifier title url assignee { displayName } state { name } }
      comment { id url body createdAt user { id displayName } }
      actor { id displayName } } } } }
GQL
LINEAR_NOTIF_TYPES = %w[issueCommentMention issueMention issueNewComment issueCommentReply].freeze
LINEAR_MENTION_TYPES = %w[issueCommentMention issueMention].freeze
LINEAR_NOTIF_MAX_AGE = 14 * 24 * 60 * 60
LINEAR_ANSWERED_LIMIT = 20

def utc_now
  Time.now.utc
end

def iso(time)
  return nil if time.nil?

  time = Time.at(time / 1000.0) if time.is_a?(Numeric)
  time = Time.parse(time.to_s) if time.is_a?(String)
  time.utc.iso8601
end

# Kill the child and everything it spawned. The child leads its own process
# group (pgroup: true), so the negative pid reaches the whole tree.
def kill_process_group(pid)
  pgid = Process.getpgid(pid)
  Process.kill("TERM", -pgid)
  return if Process.waitpid(pid, Process::WNOHANG)

  50.times do
    sleep 0.02
    return if Process.waitpid(pid, Process::WNOHANG)
  end
  Process.kill("KILL", -pgid)
  Process.waitpid(pid)
rescue Errno::ESRCH, Errno::ECHILD, Errno::EPERM
  nil
end

# Timeout.timeout cannot bound Open3.capture3: capture3's ensure joins the wait
# thread, so the call returns only when the child exits. Read the pipes against
# a deadline instead and kill the process group when it passes.
def run_cmd(*args, timeout: 15, chdir: nil, stdin_data: nil)
  opts = { pgroup: true }
  opts[:chdir] = chdir if chdir
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
  expired = false
  out = +""
  err = +""
  status = nil

  Open3.popen3(*args, **opts) do |stdin, stdout, stderr, wait_thr|
    pid = wait_thr.pid
    begin
      stdin.write(stdin_data) unless stdin_data.nil?
    rescue Errno::EPIPE
      nil
    end
    stdin.close

    readers = [stdout, stderr]
    until readers.empty?
      left = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      if left <= 0 || (ready = IO.select(readers, nil, nil, left)).nil?
        expired = true
        break
      end
      ready[0].each do |io|
        chunk = io.read_nonblock(4096)
        (io.equal?(stdout) ? out : err) << chunk
      rescue IO::WaitReadable
        next
      rescue EOFError, Errno::EIO
        readers.delete(io)
      end
    end

    unless expired
      left = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      expired = true unless wait_thr.join(left.positive? ? left : 0)
    end

    if expired
      kill_process_group(pid)
      wait_thr.join(1)
    else
      status = wait_thr.value
    end
  end

  raise "timeout after #{timeout}s: #{args.join(" ")}" if expired

  [out, err, status]
end

def tail_bytes(path, n = TAIL_BYTES)
  File.open(path, "rb") do |f|
    f.seek(0, IO::SEEK_END)
    size = f.pos
    f.seek([0, size - n].max)
    data = f.read.to_s
    incomplete = size > n
    [data, incomplete]
  end
end

def parse_jsonl_tail(path, n = TAIL_BYTES)
  return [] unless File.file?(path)

  data, incomplete = tail_bytes(path, n)
  lines = data.split("\n")
  # The first line of the window is usually a fragment of a record that
  # started before it. Dropping it is right -- unless it is the only line,
  # which means one record is larger than the window. Re-read enough to cover
  # that record rather than returning nothing: a grok session whose last event
  # was large used to vanish from the card entirely.
  if incomplete && lines.size <= 1
    grown = n
    while grown < MAX_TAIL_BYTES && lines.size <= 1
      grown *= 4
      data, incomplete = tail_bytes(path, grown)
      lines = data.split("\n")
    end
  end
  lines.shift if incomplete && lines.size > 1
  records = []
  lines.each do |line|
    line = line.strip
    next if line.empty?

    records << JSON.parse(line)
  rescue JSON::ParserError
    next
  end
  records
end

def first_jsonl_record(path)
  return nil unless File.file?(path)

  File.open(path, "rb") do |f|
    buf = +""
    while (chunk = f.read(4096))
      buf << chunk
      if (idx = buf.index("\n"))
        line = buf[0...idx].strip
        return JSON.parse(line) unless line.empty?
        buf = buf[(idx + 1)..] || ""
      end
      break if buf.bytesize > 1_000_000
    end
    JSON.parse(buf.strip) unless buf.strip.empty?
  end
rescue JSON::ParserError
  nil
end

def last_jsonl_record(path, n = TAIL_BYTES)
  parse_jsonl_tail(path, n).last
end

def proc_exists?(pid)
  pid = pid.to_i
  pid.positive? && File.directory?("/proc/#{pid}")
end

# /proc/<pid> alone is not evidence the session is alive: pid_max is 99999 and
# most session files on disk name a dead process, so a recycled pid resurrects
# an old session (and its stale needs-you row sorts to the top). Require the
# process to actually be the tool that wrote the file.
def proc_is?(pid, *names)
  return false unless proc_exists?(pid)

  comm = proc_comm(pid).to_s
  return true if names.include?(comm)

  cmdline = proc_cmdline(pid).to_s
  names.any? { |n| cmdline.match?(/(?:\A|[\/\s])#{Regexp.escape(n)}(?:\s|\z)/) }
end

def proc_cwd(pid)
  File.readlink("/proc/#{pid}/cwd")
rescue Errno::ENOENT, Errno::EACCES, Errno::ESRCH
  nil
end

def proc_comm(pid)
  File.read("/proc/#{pid}/comm").to_s.strip
rescue Errno::ENOENT, Errno::EACCES, Errno::ESRCH
  nil
end

def proc_cmdline(pid)
  File.read("/proc/#{pid}/cmdline").to_s.split("\0").join(" ")
rescue Errno::ENOENT, Errno::EACCES, Errno::ESRCH
  ""
end

def proc_ppid(pid)
  File.read("/proc/#{pid}/status")[/^PPid:\s+(\d+)/, 1]&.to_i
rescue Errno::ENOENT, Errno::EACCES, Errno::ESRCH
  nil
end

def clean_cwd(path)
  return nil if path.nil?

  path = path.sub(/ \(deleted\)\z/, "")
  path.chomp("/")
end

def under?(root, cwd)
  return false if root.nil? || cwd.nil?

  cwd == root || cwd.start_with?("#{root}/")
end

def parse_time(value)
  return nil if value.nil? || value.to_s.empty?

  Time.parse(value.to_s)
rescue ArgumentError
  nil
end

# Joins, not collection. A worktree row is a local fact; its PR and whether it
# is prunable are read from the `gh pr list` map at compose time, so a stale
# map can never leave a stale field behind on the row.
def pr_for(branch, name, detached, pr_map)
  if branch && pr_map["by_branch"]
    hit = pr_map["by_branch"][branch]
    return shape_pr(hit) if hit
  end
  if (m = name.match(/\Apr-(\d+)\z/)) && pr_map["by_number"]
    num = m[1].to_i
    hit = pr_map["by_number"][num] || pr_map["by_number"][m[1]]
    return shape_pr(hit) if hit
  end
  nil
end

def shape_pr(raw)
  return nil if raw.nil?

  {
    "number" => raw["number"],
    "state" => raw["state"],
    "draft" => raw["isDraft"] ? true : false,
    "url" => raw["url"]
  }
end

def prune?(is_main, detached, path, merged_into, pr, last_at)
  return [false, nil] if is_main

  closed = pr && %w[MERGED CLOSED].include?(pr["state"])
  tmp_detached = detached && path.start_with?("/tmp/")
  first = merged_into || closed || tmp_detached
  return [false, nil] unless first

  stale = last_at.nil? || last_at < (Time.now - PRUNE_AFTER)
  return [false, nil] unless stale

  reason =
    if merged_into
      "branch merged"
    elsif closed
      "PR #{pr["state"].downcase}"
    else
      "detached under /tmp"
    end
  [true, reason]
end

# The worktree row whose path is the deepest prefix of cwd. Linked worktrees
# sit under the main checkout, so the longest match is the owning row.
def longest_worktree(cwd, rows)
  best = nil
  rows.each do |row|
    next unless under?(row["path"], cwd)

    best = row if best.nil? || row["path"].length > best["path"].length
  end
  best
end

def hex_ip_port(hex)
  ip_hex, port_hex = hex.split(":")
  return nil if ip_hex.nil? || port_hex.nil?

  port = port_hex.to_i(16)
  [port, ip_hex]
end

# Distinct Claude session `status` values observed on this machine before mapping:
#   nil (key absent), "idle", "shell", "waiting", "busy"
# Mapping: busy|shell -> working; waiting (status or pending tool_use) -> waiting; else idle.
class Collector
  # Messages from repos whose git commands failed during the last
  # worktree_rows call. The rows of every other repo are still returned.
  attr_reader :repo_errors

  def initialize
    @listen = [] # {port:, pid:, cwd:, comm:}
    @grok_procs = []
    @codex_alive = false
    @repo_errors = []
  end

  def snapshot_processes
    @listen = listen_sockets
    @grok_procs = grok_processes
    @codex_alive = codex_process_alive?
  end

  # Local facts only. Nothing here depends on GitHub, so nothing here goes
  # stale when a `gh` call fails.
  def worktree_rows
    snapshot_processes
    rows = []
    errors = []
    activity = agent_activity
    REPOS.each do |repo|
      # One repo's git failure must not lose the other repo's rows. The caller
      # reads repo_errors and attaches it to the cards without blanking them.
      rows.concat(rows_for_repo(repo, activity))
    rescue StandardError => e
      errors << "#{repo["name"]}: #{e.message}"
    end
    @repo_errors = errors
    rows
  end

  def agent_sessions(worktree_rows)
    snapshot_processes if @listen.empty? && @grok_procs.empty?
    sessions = []
    sessions.concat(claude_sessions(worktree_rows))
    sessions.concat(grok_sessions(worktree_rows))
    sessions.concat(codex_sessions(worktree_rows))
    sessions
  end

  private

  def listen_sockets
    by_inode = {}
    parse_proc_net("/proc/net/tcp", by_inode)
    parse_proc_net("/proc/net/tcp6", by_inode)
    inode_to_pid = map_socket_inodes(by_inode.keys)
    seen = {}
    result = []
    by_inode.each do |inode, port|
      pid = inode_to_pid[inode]
      next if pid.nil?

      key = [port, pid]
      next if seen[key]

      seen[key] = true
      result << {
        port: port,
        pid: pid,
        cwd: clean_cwd(proc_cwd(pid)),
        comm: proc_comm(pid)
      }
    end
    if result.empty?
      result.concat(listen_via_ss)
    end
    result
  end

  def parse_proc_net(path, into)
    return unless File.file?(path)

    File.foreach(path) do |line|
      fields = line.split
      next unless fields[3] == "0A" # LISTEN

      port, = hex_ip_port(fields[1])
      next if port.nil? || port.zero?

      inode = fields[9]
      next if inode.nil? || inode == "0"

      into[inode] = port
    end
  rescue Errno::ENOENT, Errno::EACCES
    nil
  end

  def map_socket_inodes(inodes)
    want = {}
    inodes.each { |i| want[i] = true }
    found = {}
    Dir.each_child("/proc") do |pid_s|
      break if want.empty?
      next unless pid_s.match?(/\A\d+\z/)

      fd_dir = "/proc/#{pid_s}/fd"
      next unless File.directory?(fd_dir)

      pid = pid_s.to_i
      begin
        Dir.each_child(fd_dir) do |fd|
          target = File.readlink("#{fd_dir}/#{fd}")
          next unless target.start_with?("socket:[")

          inode = target[/\d+/]
          next unless want.delete(inode)

          found[inode] = pid
          break if want.empty?
        rescue Errno::ENOENT, Errno::EACCES, Errno::EINVAL
          next
        end
      rescue Errno::ENOENT, Errno::EACCES
        next
      end
    end
    found
  end

  def listen_via_ss
    stdout, = run_cmd("ss", "-ltnp", timeout: 5)
    out = []
    stdout.each_line do |line|
      next unless line.include?("LISTEN")

      port = line[/:(?<port>\d+)\s/, :port]&.to_i
      pid = line[/pid=(?<pid>\d+)/, :pid]&.to_i
      next if port.nil? || pid.nil?

      out << { port: port, pid: pid, cwd: clean_cwd(proc_cwd(pid)), comm: proc_comm(pid) }
    end
    out
  rescue StandardError
    []
  end

  def grok_processes
    procs = []
    Dir.each_child("/proc") do |pid_s|
      next unless pid_s.match?(/\A\d+\z/)

      pid = pid_s.to_i
      comm = proc_comm(pid)
      next unless comm == "grok"

      procs << { pid: pid, cwd: clean_cwd(proc_cwd(pid)), cmdline: proc_cmdline(pid) }
    end
    procs
  end

  def codex_process_alive?
    Dir.each_child("/proc") do |pid_s|
      next unless pid_s.match?(/\A\d+\z/)

      comm = proc_comm(pid_s.to_i)
      return true if comm == "codex"
    end
    false
  end

  def app_port_for(path)
    matches = @listen.select do |l|
      !EXCLUDED_PORTS.include?(l[:port]) && l[:cwd] == path
    end
    return pick_app_port(matches) unless matches.empty?

    nil
  end

  def pick_app_port(matches)
    rails = matches.find { |l| l[:comm].to_s.match?(/\A(ruby|puma|rails)\z/) }
    return rails[:port] if rails

    matches.map { |l| l[:port] }.min
  end

  def overmind_fallback_port(path)
    stdout, stderr, status = run_cmd("overmind", "status", timeout: 2, chdir: path)
    text = "#{stdout}#{stderr}"
    return nil unless status&.success?

    pid = nil
    text.each_line do |line|
      cols = line.split
      next unless cols.length >= 3
      next unless cols[0].match?(/\A(web|rails)\z/i)
      next unless cols[2].match?(/running/i)

      pid = cols[1].to_i
      break
    end
    return nil unless pid&.positive?

    pids = [pid]
    Dir.each_child("/proc") do |pid_s|
      next unless pid_s.match?(/\A\d+\z/)

      child = pid_s.to_i
      pids << child if proc_ppid(child) == pid
    end
    ports = @listen.select { |l| pids.include?(l[:pid]) && !EXCLUDED_PORTS.include?(l[:port]) }
    pick_app_port(ports)
  rescue StandardError
    nil
  end

  def rows_for_repo(repo, activity)
    root = repo["root"]
    stdout, stderr, status = run_cmd("git", "-C", root, "worktree", "list", "--porcelain", timeout: 20)
    raise "git worktree list: #{stderr.strip}" unless status.success?

    merged = merged_branches(root)
    records = parse_worktrees(stdout)
    wt_paths = records.map { |wt| wt[:path] }
    records.map do |wt|
      path = wt[:path]
      branch = wt[:branch]
      detached = wt[:detached]
      is_main = File.expand_path(path) == File.expand_path(root)
      name = File.basename(path)
      overmind_live = File.exist?(File.join(path, ".overmind.sock"))
      app_port = app_port_for(path)
      app_port = overmind_fallback_port(path) if app_port.nil? && overmind_live
      last_at = latest_activity(path, activity, wt_paths)
      merged_into = !detached && !branch.nil? && merged.include?(branch)
      {
        "name" => name,
        "path" => path,
        "repo" => repo["name"],
        "branch" => branch,
        "head" => wt[:head],
        "detached" => detached,
        "is_main" => is_main,
        "app_port" => app_port,
        "db_port" => repo["db_port"],
        "overmind_live" => overmind_live,
        "merged_into_develop" => merged_into,
        "last_session_at" => iso(last_at)
      }
    end
  end

  def parse_worktrees(text)
    records = []
    current = {}
    text.each_line do |line|
      line = line.chomp
      if line.empty?
        records << current unless current.empty?
        current = {}
        next
      end
      key, value = line.split(" ", 2)
      case key
      when "worktree"
        current[:path] = value
      when "HEAD"
        current[:head] = value.to_s[0, 7]
      when "branch"
        current[:branch] = value.sub(%r{\Arefs/heads/}, "")
        current[:detached] = false
      when "detached"
        current[:detached] = true
        current[:branch] = nil
      end
    end
    records << current unless current.empty?
    records.each { |r| r[:detached] = r[:branch].nil? if r[:detached].nil? }
    records
  end

  # The branch a worktree's branch merges into: what origin/HEAD points at,
  # else the first of develop, main, master that exists. nil when none does.
  def base_ref(root)
    stdout, _stderr, status = run_cmd("git", "-C", root, "symbolic-ref", "-q", "--short", "refs/remotes/origin/HEAD", timeout: 10)
    return stdout.strip if status.success? && !stdout.strip.empty?

    %w[develop main master].find do |ref|
      run_cmd("git", "-C", root, "rev-parse", "--verify", "-q", ref, timeout: 10)[2].success?
    end
  end

  def merged_branches(root)
    base = base_ref(root)
    return {} if base.nil?

    stdout, stderr, status = run_cmd("git", "-C", root, "branch", "--merged", base, timeout: 20)
    raise "git branch --merged #{base}: #{stderr.strip}" unless status.success?

    set = {}
    stdout.each_line do |line|
      # git marks the current branch with "*" and a branch checked out in a
      # linked worktree with "+". Linked worktrees are exactly what this
      # dashboard prunes, so both markers have to go.
      name = line.sub(/^[*+]/, "").strip
      next if name.empty? || name.start_with?("(")

      set[name] = true
    end
    set
  end

  # `others` are the sibling worktree paths of the same repo. Linked worktrees
  # sit under the main checkout, so without this the main row reports every
  # nested worktree's session as its own.
  def latest_activity(path, activity, others = [])
    nested = others.select { |p| p != path && under?(path, p) }
    latest = nil
    activity.each do |ev|
      next unless under?(path, ev[:cwd])
      next if nested.any? { |p| under?(p, ev[:cwd]) }

      t = ev[:at]
      next if t.nil?

      latest = t if latest.nil? || t > latest
    end
    latest
  end

  def agent_activity
    events = []
    claude_activity(events)
    grok_activity(events)
    codex_activity(events)
    events
  end

  def claude_activity(events)
    Dir.glob(File.join(HOME, ".claude/sessions/*.json")).each do |path|
      data = JSON.parse(File.read(path))
      cwd = clean_cwd(data["cwd"])
      at = ms_time(data["updatedAt"]) || ms_time(data["startedAt"])
      events << { cwd: cwd, at: at } if cwd && at
    rescue StandardError
      next
    end
  end

  def grok_activity(events)
    each_grok_event_file do |cwd, file|
      rec = last_jsonl_record(file)
      next unless rec

      at = parse_time(rec["ts"]) || File.mtime(file)
      events << { cwd: cwd, at: at }
    end
  end

  # Activity feeds the 14-day prune rule, so it has to cover 14 days. Reading
  # only today's directory made any worktree whose last agent was Codex look
  # untouched, and prune? treats missing activity as stale. The timestamp is
  # the file mtime, not the rollout's first record: a session that starts
  # before midnight and runs for hours is last active at the end, not the
  # start.
  def codex_activity(events)
    root = File.join(HOME, ".codex/sessions")
    return unless File.directory?(root)

    today = Date.today
    (0..(PRUNE_AFTER / 86_400)).each do |back|
      day = today - back
      Dir.glob(File.join(root, day.strftime("%Y/%m/%d"), "rollout-*.jsonl")).each do |file|
        rec = first_jsonl_record(file)
        cwd = rec&.dig("payload", "cwd")
        next if cwd.nil?

        at = File.mtime(file)
        events << { cwd: clean_cwd(cwd), at: at }
      rescue StandardError
        next
      end
    end
  end

  def each_grok_event_file
    root = File.join(HOME, ".grok/sessions")
    return unless File.directory?(root)

    Dir.each_child(root) do |enc|
      dir = File.join(root, enc)
      next unless File.directory?(dir)

      # CGI.unescape decodes "+" as a space, which is form encoding, not path
      # encoding. A directory name that holds a literal "+" has to survive.
      cwd = clean_cwd(CGI.unescape(enc.gsub("+", "%2B")))
      Dir.each_child(dir) do |uuid|
        file = File.join(dir, uuid, "events.jsonl")
        next unless File.file?(file)

        yield cwd, file, uuid
      end
    end
  end

  def attach_worktree(session, rows)
    row = longest_worktree(session["cwd"], rows)
    session["worktree"] = row && row["name"]
    session
  end

  def claude_sessions(rows)
    sessions = []
    Dir.glob(File.join(HOME, ".claude/sessions/*.json")).each do |path|
      data = JSON.parse(File.read(path))
      pid = data["pid"]
      next unless proc_is?(pid, "claude", "node")

      sid = data["sessionId"]
      cwd = clean_cwd(data["cwd"])
      status = data["status"]
      state, detail = claude_state(data, cwd, sid, status)
      sessions << attach_worktree({
        "tool" => "claude",
        "id" => sid,
        "cwd" => cwd,
        "worktree" => nil,
        "state" => state,
        "detail" => detail,
        "name" => data["name"],
        "pid" => pid,
        "alive" => true,
        "started_at" => iso(ms_time(data["startedAt"])),
        "updated_at" => iso(ms_time(data["updatedAt"])),
        "resume_command" => nil
      }, rows)
    rescue StandardError
      next
    end
    sessions
  end

  def claude_state(data, cwd, sid, status)
    if status == "busy" || status == "shell"
      return ["working", status_detail(status, data)]
    end

    pending = pending_tool_use(cwd, sid)
    if pending || status == "waiting"
      detail = pending || data["waitingFor"] || "waiting on a permission prompt"
      return ["waiting", detail]
    end

    ["idle", status_detail(status, data)]
  end

  def status_detail(status, data)
    return data["waitingFor"] if data["waitingFor"]
    return "status: #{status}" if status

    nil
  end

  def pending_tool_use(cwd, sid)
    return nil if cwd.nil? || sid.nil?

    # Claude Code maps every non-alphanumeric character to "-", not just the
    # separator. A path with a dot or an underscore (.claude/worktrees,
    # qual_7013) resolved to a directory that does not exist, so the pending
    # tool never showed for those sessions.
    proj = cwd.gsub(/[^A-Za-z0-9]/, "-")
    path = File.join(HOME, ".claude/projects", proj, "#{sid}.jsonl")
    records = parse_jsonl_tail(path, TAIL_BYTES)
    records.reject! { |r| r["type"] == "system" || r["type"] == "attachment" }
    last = records.last
    return nil unless last

    msg = last["message"]
    return nil unless last["type"] == "assistant" && msg.is_a?(Hash)

    content = msg["content"]
    return nil unless content.is_a?(Array)

    tool = content.find { |c| c.is_a?(Hash) && c["type"] == "tool_use" }
    return nil unless tool
    return nil if content.any? { |c| c.is_a?(Hash) && c["type"] == "tool_result" }

    format_tool_use(tool)
  rescue StandardError
    nil
  end

  def format_tool_use(tool)
    name = tool["name"].to_s
    input = tool["input"]
    input = {} unless input.is_a?(Hash)
    arg = input["command"] || input["file_path"] || input["path"] || input["pattern"] || input["query"]
    arg = arg.to_s.split("\n", 2).first.to_s.strip
    arg = arg[0, 160]
    arg.empty? ? name : "#{name}: #{arg}"
  end

  def grok_sessions(rows)
    cutoff = Time.now - GROK_MAX_AGE
    candidates = []
    each_grok_event_file do |cwd, file, uuid|
      next if GROK_IGNORED_CWDS.include?(cwd)

      rec = last_jsonl_record(file)
      next unless rec

      updated = parse_time(rec["ts"]) || File.mtime(file)
      next if updated && updated < cutoff

      first = first_jsonl_record(file)
      candidates << {
        cwd: cwd, uuid: uuid, rec: rec, updated: updated,
        started: parse_time(first && first["ts"])
      }
    rescue StandardError
      next
    end

    # Only the most recently updated session in a directory may be claimed by
    # an unnamed process running there. See grok_alive.
    newest = {}
    candidates.each do |c|
      cur = newest[c[:cwd]]
      newest[c[:cwd]] = c if cur.nil? || (c[:updated] && cur[:updated] && c[:updated] > cur[:updated])
    end

    candidates.map do |c|
      rec = c[:rec]
      alive_proc = grok_alive(c[:cwd], c[:uuid], newest: newest[c[:cwd]].equal?(c))
      alive = !alive_proc.nil?
      type = rec["type"].to_s
      outcome = rec["outcome"].to_s
      state, detail =
        if alive
          ["working", grok_detail(rec)]
        elsif type == "turn_ended" && outcome == "completed"
          ["idle", grok_detail(rec)]
        else
          ["unconfirmed", grok_detail(rec)]
        end
      attach_worktree({
        "tool" => "grok",
        "id" => c[:uuid],
        "cwd" => c[:cwd],
        "worktree" => nil,
        "state" => state,
        "detail" => detail,
        "name" => nil,
        "pid" => alive_proc && alive_proc[:pid],
        "alive" => alive,
        "started_at" => iso(c[:started]),
        "updated_at" => iso(c[:updated]),
        "resume_command" => "grok --resume #{c[:uuid]}"
      }, rows)
    end
  end

  # A uuid on the command line is proof of which session a process belongs to.
  # A bare cwd match is not: every session ever run in that directory shares
  # the cwd, so matching on it alone marked years of dead sessions "working"
  # and handed each one the live process's pid. The cwd arm now only claims a
  # process that names no session at all, and only for the newest session in
  # that directory (`newest` is set by the caller).
  def grok_alive(cwd, uuid, newest: false)
    named = @grok_procs.find { |proc| proc[:cmdline].include?(uuid) }
    return named if named
    return nil unless newest

    @grok_procs.find do |proc|
      proc[:cwd] == cwd && !proc[:cmdline].match?(GROK_UUID_RE)
    end
  end

  def grok_detail(rec)
    type = rec["type"].to_s
    extra = rec["outcome"] || rec["phase"] || rec["server_name"]
    if extra
      "last event: #{type} (#{extra})"
    else
      "last event: #{type}"
    end
  end

  def codex_sessions(rows)
    sessions = []
    today = File.join(HOME, ".codex/sessions", Time.now.strftime("%Y/%m/%d"))
    Dir.glob(File.join(today, "rollout-*.jsonl")).each do |file|
      rec = first_jsonl_record(file)
      payload = rec && rec["payload"]
      cwd = clean_cwd(payload && payload["cwd"])
      id = (payload && (payload["id"] || payload["session_id"])) || File.basename(file, ".jsonl")
      started = parse_time(rec && rec["timestamp"]) || parse_time(payload && payload["timestamp"])
      mtime = File.mtime(file)
      working = @codex_alive && (Time.now - mtime) < CODEX_WORKING_MTIME
      sessions << attach_worktree({
        "tool" => "codex",
        "id" => id,
        "cwd" => cwd,
        "worktree" => nil,
        "state" => working ? "working" : "idle",
        "detail" => working ? "mtime under 2m" : "idle",
        "name" => nil,
        "pid" => nil,
        "alive" => working,
        "started_at" => iso(started),
        "updated_at" => iso(mtime),
        "resume_command" => nil
      }, rows)
    rescue StandardError
      next
    end
    sessions
  end

  def ms_time(value)
    return nil if value.nil?

    Time.at(value.to_f / 1000.0)
  end
end

# fetch reads cached snapshots only. It does not call the network.
#
# Snapshot name is not the source id: github reads "prs", agent reads
# "local", machine reads "machines". Linear rows are built from the composed
# linear projection (group and worktree joins). Those joins stay out of the
# source cache; compose_cards builds them and the adapter reads that
# projection. Agent rows read the local snapshot's sessions. Quota, machines,
# and GitHub read their own snapshots. The needs_you_from_* methods are the
# predicate bodies each adapter calls. build_needs_you only flat-maps fetch,
# so they are not a second writer. SlackAdapter is an empty slot: no client,
# no credentials, no rows.
module NeedsYou
  class Adapter
    def source_id
      raise NotImplementedError
    end

    def fetch(_ctx)
      raise NotImplementedError
    end
  end

  class MemoryContext
    attr_reader :worktrees

    def initialize(snapshots:, worktrees: [], fetched_at: {})
      @snapshots = snapshots
      @worktrees = worktrees || []
      @fetched_at = fetched_at || {}
    end

    def snapshot(name)
      @snapshots[name]
    end

    def fetched_at(name)
      @fetched_at[name]
    end
  end

  class GithubAdapter < Adapter
    def initialize(server)
      @server = server
    end

    def source_id
      "github"
    end

    def fetch(ctx)
      prs = ctx.snapshot("prs")
      return [] if prs.nil?

      @server.send(:needs_you_from_prs, prs, ctx.worktrees)
    end
  end

  class LinearAdapter < Adapter
    def initialize(server)
      @server = server
    end

    def source_id
      "linear"
    end

    def fetch(ctx)
      linear = ctx.snapshot("linear")
      return [] if linear.nil?

      @server.send(:needs_you_from_linear, linear, ctx.worktrees)
    end
  end

  class AgentAdapter < Adapter
    def initialize(server)
      @server = server
    end

    def source_id
      "agent"
    end

    def fetch(ctx)
      local = ctx.snapshot("local")
      return [] if local.nil?

      sessions = local.is_a?(Hash) ? local["sessions"] : local
      sessions = [] unless sessions.is_a?(Array)
      @server.send(:needs_you_from_agents, sessions)
    end
  end

  class MachineAdapter < Adapter
    def initialize(server)
      @server = server
    end

    def source_id
      "machine"
    end

    def fetch(ctx)
      machines = ctx.snapshot("machines")
      return [] if machines.nil?

      @server.send(:needs_you_from_machines, machines)
    end
  end

  class QuotaAdapter < Adapter
    def initialize(server)
      @server = server
    end

    def source_id
      "quota"
    end

    def fetch(ctx)
      quota = ctx.snapshot("quota")
      return [] if quota.nil?

      @server.send(:needs_you_from_quota, quota)
    end
  end

  class SlackAdapter < Adapter
    def source_id
      "slack"
    end

    # Empty until a later change fills a slack snapshot. No HTTP client.
    def fetch(_ctx)
      []
    end
  end
end

class OpsTabServer
  def initialize
    @mutex = Mutex.new
    @collector = Collector.new
    @local_error = nil
    @remote_error = nil
    @prs_error = nil
    @linear_error = nil
    @linear_mentions_error = nil
    @quota_error = nil
    @machines_error = nil
    @linear_key = nil
    @ping_cache = {}
    @pr_maps = REPOS.to_h { |repo| [repo["name"], empty_pr_map] }
    # What each source last returned, and nothing derived from another source.
    # `local` carries worktree rows and agent sessions from the same tick, so
    # the two cards it feeds can never disagree about which tick they are on.
    @sources = {
      "local" => empty_source,
      "pings" => empty_source,
      "prs" => empty_source,
      "linear" => empty_source,
      "quota" => empty_source,
      "machines" => empty_source
    }
    load_cache
    load_overlay
    @linear_key = read_linear_key
    if @linear_key.nil?
      # Documented behaviour: no key means the Linear card serves nothing, not
      # a cached copy of what it held before the key went missing.
      @linear_error = NO_LINEAR_KEY
      @sources["linear"] = empty_source
    end
    @http = WEBrick::HTTPServer.new(
      BindAddress: BIND_HOST,
      Port: BIND_PORT,
      AccessLog: [],
      Logger: WEBrick::Log.new($stderr, WEBrick::Log::INFO)
    )
    @http.mount_proc("/cards") { |req, res| handle_cards(req, res) }
    @http.mount_proc("/health") { |req, res| handle_health(req, res) }
    @http.mount_proc("/needs_you/summary") { |req, res| handle_needs_you_summary(req, res) }
    @http.mount_proc("/needs_you/overlay") { |req, res| handle_needs_you_overlay(req, res) }
    trap("INT") { @http.shutdown }
    trap("TERM") { @http.shutdown }
  end

  def run
    start_threads
    warn "ops-tab listening on #{BIND_HOST}:#{BIND_PORT}"
    @http.start
  end

  private

  def empty_pr_map
    { "by_branch" => {}, "by_number" => {}, "loaded" => false }
  end

  def empty_source
    { "data" => nil, "fetched_at" => nil }
  end

  def source(name)
    @sources[name] || empty_source
  end

  def source_data(name)
    source(name)["data"]
  end

  def load_cache
    return unless File.file?(CACHE_PATH)

    parsed = JSON.parse(File.read(CACHE_PATH))
    load_sources(parsed)
    load_pr_maps(parsed)
    warn "loaded cache from #{CACHE_PATH} local.fetched_at=#{source("local")["fetched_at"]}"
  rescue StandardError => e
    warn "cache load failed: #{e.message}"
  end

  def load_sources(parsed)
    saved = parsed["sources"]
    if saved.is_a?(Hash)
      @sources.each_key do |key|
        @sources[key] = saved[key] if saved[key].is_a?(Hash)
      end
      return
    end
    # A cache written before sources existed. Its `prs`, `linear` and `quota`
    # entries are source data with derived fields on top, which compose
    # recomputes, so they are worth keeping across the upgrade. `worktrees`
    # and `agents` are not: the local tick replaces them within seconds.
    cards = parsed["cards"]
    return unless cards.is_a?(Hash)

    %w[prs linear quota].each do |key|
      card = cards[key]
      next unless card.is_a?(Hash) && !card["data"].nil?

      @sources[key] = { "data" => card["data"], "fetched_at" => card["fetched_at"] }
    end
  end

  def load_pr_maps(parsed)
    return unless parsed["pr_maps"].is_a?(Hash)

    parsed["pr_maps"].each do |name, mmap|
      next unless mmap.is_a?(Hash)

      @pr_maps[name] = {
        "by_branch" => mmap["by_branch"] || {},
        "by_number" => (mmap["by_number"] || {}).transform_keys { |k| k.to_i },
        "loaded" => true
      }
    end
  end

  def save_cache
    FileUtils.mkdir_p(File.dirname(CACHE_PATH))
    tmp = "#{CACHE_PATH}.tmp"
    payload = {
      "sources" => @sources,
      "pr_maps" => @pr_maps
    }
    File.write(tmp, JSON.generate(payload))
    File.rename(tmp, CACHE_PATH)
  end

  def load_overlay
    @overlay = { "version" => 1, "entries" => {} }
    return unless File.file?(OVERLAY_PATH)

    parsed = JSON.parse(File.read(OVERLAY_PATH))
    unless parsed.is_a?(Hash) && parsed["version"] == 1 && parsed["entries"].is_a?(Hash)
      warn "needs-you overlay left unread (unknown version or shape)"
      return
    end

    @overlay = { "version" => 1, "entries" => parsed["entries"] }
  rescue JSON::ParserError => e
    warn "needs-you overlay left unread: #{e.message}"
  end

  def save_overlay
    FileUtils.mkdir_p(File.dirname(OVERLAY_PATH))
    tmp = "#{OVERLAY_PATH}.tmp"
    File.write(tmp, JSON.generate(@overlay))
    File.rename(tmp, OVERLAY_PATH)
  end

  def start_threads
    Thread.new do
      loop do
        refresh_local
        sleep LOCAL_INTERVAL
      end
    rescue StandardError => e
      warn "local refresh thread: #{e.message}"
      sleep LOCAL_INTERVAL
      retry
    end
    Thread.new do
      loop do
        refresh_remote
        sleep REMOTE_INTERVAL
      end
    rescue StandardError => e
      warn "remote refresh thread: #{e.message}"
      sleep REMOTE_INTERVAL
      retry
    end
  end

  def refresh_local
    # Fleet is its own source. A git failure must not skip it, and a bad fleet
    # cache must not blank worktrees or agents.
    started = iso(utc_now)
    machines_data, machines_err = fetch_machines_result
    rows = nil
    sessions = nil
    pings = nil
    repo_errors = []
    local_err = nil
    begin
      rows = @collector.worktree_rows
      repo_errors = @collector.repo_errors
      # Every repo failed, so there is nothing to show. Leave the last good
      # local source in place.
      if repo_errors.size >= REPOS.size && !repo_errors.empty?
        rows = nil
        raise repo_errors.join("; ")
      end

      sessions = @collector.agent_sessions(rows)
      # The pings are the only part of the local tick that touches the network,
      # so they are collected here and joined to rows at compose time.
      pings = collect_pings(rows)
    rescue StandardError => e
      rows = nil
      local_err = e.message
      warn "local refresh: #{e.message}"
    end
    now = iso(utc_now)
    @mutex.synchronize do
      if rows
        # Partial failure: keep the repos that worked and say which one did not.
        @local_error = repo_errors.empty? ? nil : repo_errors.uniq.join("; ")
        @sources["local"] = { "data" => { "rows" => rows, "sessions" => sessions }, "fetched_at" => now, "refresh_started_at" => started }
        @sources["pings"] = { "data" => pings, "fetched_at" => now, "refresh_started_at" => started }
      elsif local_err
        @local_error = local_err
      end
      if machines_data
        @machines_error = nil
        @sources["machines"] = { "data" => machines_data, "fetched_at" => now, "refresh_started_at" => started }
      elsif machines_err
        @machines_error = machines_err
        warn "machines: #{machines_err}"
      end
      save_cache if rows || machines_data
    end
    return unless rows

    warn "local refresh complete fetched_at=#{now}#{repo_errors.empty? ? "" : " partial=#{repo_errors.uniq.join("; ")}"}"
  end

  # Each leg runs in its own thread and reports [value, nil] or [nil, message].
  # A leg never raises into the refresh loop.
  def run_legs(legs)
    legs.map do |name, leg|
      Thread.new do
        [name, [leg.call, nil]]
      rescue StandardError => e
        [name, [nil, e.message]]
      end
    end.map(&:value).to_h
  end

  # { port => [ping, ...] } for every app port on the rows, at most one probe
  # per port per PING_INTERVAL.
  def collect_pings(rows)
    ports = {}
    rows.each do |row|
      port = row["app_port"]
      next if port.nil? || EXCLUDED_PORTS.include?(port)

      ports[port.to_i] ||= row["repo"]
    end
    ports.to_h { |port, repo| [port.to_s, pings_for_port(port, repo)] }
  end

  def refresh_remote
    # No leg reads another's result, so they run together. The window where one
    # slow vendor holds up the rest is the slowest leg, not their sum.
    # Stamp the start before the vendor calls so a click during this refresh
    # is not confirmed by the result (opinion 5).
    started = iso(utc_now)
    legs = run_legs(
      "linear" => -> { fetch_linear },
      "quota" => -> { fetch_quota },
      # Build into a local and only publish once every repo succeeded. An
      # empty or partial hash is truthy, so assigning `maps` before the loop
      # made a failed fetch look like a successful refresh that found no PRs.
      "maps" => -> { REPOS.to_h { |repo| [repo["name"], fetch_pr_map(repo["name"])] } },
      "prs" => -> { fetch_prs }
    )
    linear_data, linear_err = legs["linear"]
    quota_data, quota_err = legs["quota"]
    maps, maps_err = legs["maps"]
    prs_data, prs_err = legs["prs"]
    warn "remote linear: #{linear_err}" if linear_err && linear_err != NO_LINEAR_KEY
    warn "remote quota: #{quota_err}" if quota_err
    warn "remote pr maps: #{maps_err}" if maps_err
    warn "remote prs: #{prs_err}" if prs_err
    now = iso(utc_now)
    @mutex.synchronize do
      if maps
        @remote_error = nil
        @pr_maps = maps
      else
        @remote_error = maps_err
      end
      if prs_data
        @prs_error = nil
        @sources["prs"] = { "data" => prs_data, "fetched_at" => now, "refresh_started_at" => started }
      else
        @prs_error = prs_err
      end
      if linear_data
        @linear_error = @linear_mentions_error
        @sources["linear"] = { "data" => linear_data, "fetched_at" => now, "refresh_started_at" => started }
      elsif linear_err == NO_LINEAR_KEY
        @linear_error = NO_LINEAR_KEY
        @sources["linear"] = empty_source
      else
        @linear_error = linear_err
      end
      if quota_data
        @quota_error = nil
        @sources["quota"] = { "data" => quota_data, "fetched_at" => now, "refresh_started_at" => started }
      else
        @quota_error = quota_err
      end
      save_cache
    end
    warn "remote refresh complete fetched_at=#{now} prs=#{prs_data ? "ok" : prs_err} linear=#{linear_data ? "ok" : linear_err} quota=#{quota_data ? "ok" : quota_err}"
  end

  def fetch_pr_map(repo)
    stdout, stderr, status = run_cmd(
      "gh", "pr", "list",
      "-R", github_repo(repo),
      "--state", "all",
      "--limit", "300",
      "--json", "number,state,isDraft,headRefName,url,mergedAt",
      timeout: 60
    )
    raise "gh pr list #{repo}: #{stderr.strip}" unless status.success?

    list = JSON.parse(stdout)
    by_branch = {}
    by_number = {}
    list.each do |pr|
      by_number[pr["number"]] = pr
      name = pr["headRefName"]
      next if name.nil? || name.empty?

      existing = by_branch[name]
      if existing.nil? || (pr["state"] == "OPEN" && existing["state"] != "OPEN")
        by_branch[name] = pr
      end
    end
    { "by_branch" => by_branch, "by_number" => by_number, "loaded" => true }
  end

  def fetch_prs
    mine_hits = gh_search_prs(
      "--author=@me",
      "number,title,repository,isDraft,url,updatedAt,createdAt"
    )
    review_hits = gh_search_prs(
      "--review-requested=@me",
      "number,title,repository,isDraft,url,updatedAt,createdAt,author",
      extra: ["--sort", "updated", "--order", "desc"]
    )
    unique = []
    seen = {}
    (mine_hits + review_hits).each do |hit|
      key = pr_search_key(hit)
      next if key.nil? || seen[key]

      seen[key] = true
      unique << hit
    end
    details = unique.empty? ? {} : graphql_pr_details(unique)
    mine = mine_hits.map { |hit| shape_pr_row(hit, details[pr_search_key(hit)], :mine) }
    review = []
    team = []
    # Raw team candidates, before the card's predicate and before the 15 cap.
    # The card still slices review_requested_team. Needs-you reads this list.
    candidates = []
    review_hits.each do |hit|
      gql = details[pr_search_key(hit)]
      shaped = shape_pr_row(hit, gql, :review)
      candidates << shaped.dup if shaped["team_requested"]
      if keep_review_requested?(hit, gql)
        review << shaped
      elsif keep_review_requested_team?(hit, gql)
        row = shaped.dup
        row["requested_via"] = "team"
        team << row
      end
    end
    team.sort_by! { |r| r["updated_at"].to_s }.reverse!
    pack_review_snapshot(mine, review, team, candidates, review_hits.size)
  end

  # The card lists are capped. team_ask_candidates is not.
  def pack_review_snapshot(mine, review, team, candidates, review_hits_size)
    {
      "mine" => mine,
      "review_requested" => review.first(REVIEW_KEEP_LIMIT),
      "review_requested_team" => team.first(REVIEW_TEAM_KEEP_LIMIT),
      "team_ask_candidates" => candidates,
      "counts" => {
        "mine" => mine.size,
        "review_requested" => review.size,
        "review_requested_team" => team.size,
        "review_requested_raw" => review_hits_size,
        "team_ask_candidates" => candidates.size
      }
    }
  end

  def github_repo(name)
    return name if GITHUB_ORG.empty?

    "#{GITHUB_ORG}/#{name}"
  end

  def read_linear_key
    return nil if LINEAR_OP_REF.empty?
    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    return nil if @op_backoff_until && now < @op_backoff_until

    stdout, stderr, status = run_cmd(OPX, "read", LINEAR_OP_REF, timeout: 20)
    # The service account's rate limit is shared with other tools; retrying every refresh keeps it exhausted.
    if stderr.to_s.include?("Too many requests")
      @op_backoff_until = now + OP_RATE_LIMIT_BACKOFF
      warn "linear key read rate-limited; next try in #{OP_RATE_LIMIT_BACKOFF / 60} min"
      return nil
    end
    key = stdout.to_s.delete("\r").strip
    return nil unless status&.success? && !key.empty?

    key
  rescue StandardError => e
    warn "linear key read failed: #{e.class}: #{e.message}"
    nil
  end

  def ensure_linear_key
    return @linear_key if @linear_key && !@linear_key.empty?

    @linear_key = read_linear_key
  end

  def fetch_linear
    key = ensure_linear_key
    raise NO_LINEAR_KEY if key.nil? || key.empty?

    parsed = linear_graphql(key)
    viewer = parsed.dig("data", "viewer")
    raise "linear graphql: no viewer" unless viewer.is_a?(Hash)

    nodes = viewer.dig("assignedIssues", "nodes")
    nodes = [] unless nodes.is_a?(Array)
    state_names = nodes.map { |n| n.dig("state", "name") }.compact.uniq.sort
    warn "linear distinct state.name before mapping: #{state_names.join(" | ")}"

    viewer_id = viewer["id"]
    mine = nodes.map { |issue| shape_linear_row(issue, viewer_id) }
    { "mine" => mine, "mentions" => fetch_linear_mentions_safe(key, viewer_id) }
  end

  def fetch_machines_result
    [fetch_machines, nil]
  rescue StandardError => e
    [nil, e.message]
  end

  # Always returns a machines payload. A missing cache is unknown rows, not a
  # failure. A corrupt cache raises so the last good source stays put.
  def fetch_machines
    maybe_spawn_fleet
    shape_fleet(read_fleet_cache)
  end

  def maybe_spawn_fleet
    return unless File.executable?(FLEET_BIN)

    FileUtils.mkdir_p(FLEET_DIR)
    mtime = File.file?(FLEET_CACHE) ? File.mtime(FLEET_CACHE) : nil
    return if mtime && (Time.now - mtime) <= FLEET_STALE

    pid = Process.spawn(
      "timeout", FLEET_TIMEOUT.to_s,
      "flock", "-n", FLEET_LOCK,
      FLEET_BIN, "--quiet",
      in: "/dev/null",
      out: "/dev/null",
      err: "/dev/null"
    )
    Process.detach(pid)
    warn "fleet reader spawned pid=#{pid}"
  rescue StandardError => e
    warn "fleet spawn: #{e.message}"
  end

  def read_fleet_cache
    return nil unless File.file?(FLEET_CACHE)

    parsed = JSON.parse(File.read(FLEET_CACHE))
    raise "fleet cache is not an object" unless parsed.is_a?(Hash)
    raise "fleet cache v #{parsed["v"].inspect}" unless parsed["v"] == 1

    parsed
  end

  def shape_fleet(cache)
    by_id = {}
    if cache.is_a?(Hash) && cache["machines"].is_a?(Array)
      cache["machines"].each do |raw|
        next unless raw.is_a?(Hash)

        id = fleet_canon(raw["id"])
        next if id.empty?

        by_id[id] = raw
      end
    end
    ids = FLEET_EXPECTED.map { |row| row["id"] }
    by_id.each_key { |id| ids << id unless ids.include?(id) }
    now = utc_now
    {
      "machines" => ids.map { |id| shape_machine(id, by_id[id], now, cache.nil?) },
      "cache_as_of" => cache.is_a?(Hash) ? cache["as_of"] : nil,
      "cache_present" => !cache.nil?
    }
  end

  def fleet_canon(value)
    key = value.to_s.strip
    return "" if key.empty?

    down = key.downcase
    return "surface" if down == "surface"
    return "BLD" if down == "bld"

    key
  end

  def fleet_label(id, raw)
    expected = FLEET_EXPECTED.find { |row| row["id"] == id }
    return expected["label"] if expected

    label = raw.is_a?(Hash) ? raw["label"].to_s.strip : ""
    label.empty? ? id : label
  end

  def shape_machine(id, raw, now, _cache_missing)
    raw = {} unless raw.is_a?(Hash)
    link = effective_fleet_link(raw, now)
    hb_last = raw["heartbeat_last"]
    hb_last = nil if hb_last.nil? || hb_last.to_s.strip.empty?
    age = heartbeat_age(hb_last, now)
    note = raw["note"]
    note = note.is_a?(String) && !note.strip.empty? ? note.strip : nil
    {
      "id" => id,
      "label" => fleet_label(id, raw),
      "expected_always_on" => FLEET_EXPECTED.any? { |row| row["id"] == id },
      "link" => link,
      "link_as_of" => raw["link_as_of"],
      "heartbeat_last" => hb_last,
      "heartbeat_age_s" => age,
      "heartbeat" => heartbeat_state(age),
      "note" => note
    }
  end

  # Effective link for the needs-you rule; the card does not draw it. A link
  # stored without a timestamp, or older than LINK_FRESH_S, is unknown. The
  # heartbeat is not an input.
  def effective_fleet_link(raw, now)
    link = raw["link"].to_s
    return "unknown" unless %w[connected disconnected].include?(link)

    as_of = parse_time(raw["link_as_of"])
    return "unknown" if as_of.nil? || (now - as_of) > LINK_FRESH_S

    link
  end

  def heartbeat_age(hb_last, now)
    stamp = parse_time(hb_last)
    return nil if stamp.nil?

    [0, (now - stamp).round].max
  end

  def heartbeat_state(age)
    return "unknown" if age.nil?

    age < HEARTBEAT_LIVE_S ? "live" : "dead"
  end

  # The groups and their order come from quartermaster's seat_rows, the cache's
  # "seats" list. A group orderly knows keeps its own rows: labels, plan, the 5h
  # track, Fable's absent state. Any other group gets one plain row per bar, so
  # a pool seat-usage adds shows up here with no change to this file.
  # Each runs on the server instance (instance_exec), so it reaches the private builders.
  QUOTA_GROUPS = {
    "cl" => ->(c, v) { [quota_claude_weekly(c, v), quota_claude_fable(c, v)] },
    "cx" => ->(c, v) { [quota_codex(c, v)] },
    "cu" => lambda { |c, v|
      [quota_cursor(c, v, "cursor_models", "cursor_auto", "Cursor Models"),
       quota_cursor(c, v, "cursor_other", "cursor_api", "Other Models"), quota_grokbot(c, v)]
    },
    "gk" => ->(c, v) { [quota_supergrok(c, v)] },
    "mu" => ->(c, v) { [quota_muse(c, v)] }
  }.freeze

  # A cache with no "seats" list (none yet, or written before seat_rows) still
  # gets the groups orderly knows, each as unknown.
  def quota_groups(cache)
    rows = cache.is_a?(Hash) ? cache["seats"] : nil
    return QUOTA_GROUPS.keys.map { |id| { "id" => id } } unless rows.is_a?(Array)

    rows.select { |g| g.is_a?(Hash) && g["id"].is_a?(String) }
  end

  def fetch_quota
    maybe_spawn_seat_usage
    cache = read_seat_usage_cache
    verified = cache_ts_iso(cache)
    seats = quota_groups(cache).flat_map do |group|
      known = QUOTA_GROUPS[group["id"]]
      known ? instance_exec(cache, verified, &known) : row_quota_seats(cache, verified, group)
    end
    {
      "seats" => seats.map { |seat| seat.merge(quota_renewal(cache, seat["seat"], seat["subscription"])).merge(quota_read(cache, seat)) },
      "host_suggestion" => fetch_host_suggestion
    }
  end

  # The router's host answer, from the cache only. --cached never calls a
  # vendor. A failure leaves the field null; the seats above still stand.
  # selects stays false: the line is a suggestion and launches nothing.
  # Each candidate host's state and the window that binds it, so the page
  # can say why the router passed it over.
  def host_entries(rows)
    return [] unless rows.is_a?(Array)

    rows.select { |h| h.is_a?(Hash) && h["id"].is_a?(String) }.map do |h|
      {
        "id" => h["id"],
        "state" => h["state"].is_a?(String) ? h["state"] : nil,
        "binding" => h["binding"].is_a?(String) ? h["binding"] : nil,
        "used_pct" => h["used_pct"].is_a?(Numeric) ? h["used_pct"] : nil
      }
    end
  end

  def fetch_host_suggestion
    stdout, stderr, status = run_cmd(
      SEAT_USAGE_BIN, "--route", "host", "--cached", "--json",
      timeout: 5
    )
    unless status&.success?
      warn "host suggestion: #{stderr.to_s.strip}"
      return nil
    end

    rows = JSON.parse(stdout)
    row = rows.is_a?(Array) ? rows.first : nil
    return nil unless row.is_a?(Hash) && row["role"] == "host"

    reason = row["reason"]
    lean = row["lean"]
    {
      "suggestion" => row["suggestion"],
      "seat" => row["seat"],
      "family" => row["family"],
      "effort" => row["effort"],
      "mode" => row["mode"],
      "reason" => reason.is_a?(String) && !reason.empty? ? reason : nil,
      "lean" => lean.is_a?(Array) ? lean.select { |id| id.is_a?(String) } : [],
      "reading_age_s" => row["reading_age_s"].is_a?(Numeric) ? row["reading_age_s"] : nil,
      "selects" => row["selects"] == true,
      "hosts" => host_entries(row["hosts"])
    }
  rescue StandardError => e
    warn "host suggestion: #{e.message}"
    nil
  end

  # The subscription each pool belongs to: [paid-through key, will-renew key,
  # source]. Grok Bot is billed on the Cursor seat. Claude has no endpoint, so
  # seat-usage reads its date from a file kept by hand.
  RENEWAL_KEYS = {
    "claude" => ["claude_renews_ts", "claude_renews", "by hand"],
    "codex" => ["codex_renews_ts", "codex_renews", "live"],
    "cursor" => ["cursor_reset_ts", "cursor_renews", "live"],
    "grok" => ["grok_renews_ts", "grok_renews", "live"]
  }.freeze

  # A hand-kept Claude date with no clock is a calendar day, not midnight.
  # The cache flag is written by seat-usage. An older cache still has the file.
  def claude_term_day(cache)
    on = cache["claude_renews_on"]
    return on if cache["claude_renews_date_only"] == true && on.is_a?(String) && on.match?(/\A\d{4}-\d{2}-\d{2}\z/)
    return nil if cache.key?("claude_renews_date_only")

    data = JSON.parse(File.read(File.expand_path("~/.config/seat-usage/renewals.json")))
    at = data.dig("claude", "at")
    at if at.is_a?(String) && at.match?(/\A\d{4}-\d{2}-\d{2}\z/)
  rescue StandardError
    nil
  end

  def quota_renewal(cache, seat, subscription = nil)
    sub =
      if subscription then subscription
      elsif seat.start_with?("claude") then "claude"
      elsif seat.start_with?("cursor") || seat == "grokbot" then "cursor"
      elsif seat == "supergrok" then "grok"
      else seat
      end
    pair = RENEWAL_KEYS[sub]
    return { "renews_at" => nil, "renews" => nil, "renews_source" => nil,
             "renews_date_only" => false, "renews_on" => nil } unless pair

    ts_key, renews_key, source = pair
    ts = ts_key && quota_num(cache, ts_key)
    return { "renews_at" => nil, "renews" => nil, "renews_source" => nil,
             "renews_date_only" => false, "renews_on" => nil } if ts.nil?

    renews = cache[renews_key]
    on = sub == "claude" ? claude_term_day(cache) : nil
    {
      "renews_at" => iso(Time.at(ts)),
      "renews" => [true, false].include?(renews) ? renews : nil,
      "renews_source" => source,
      "renews_date_only" => !on.nil?,
      "renews_on" => on
    }
  end

  def maybe_spawn_seat_usage
    FileUtils.mkdir_p(SEAT_USAGE_DIR)
    mtime = File.file?(SEAT_USAGE_CACHE) ? File.mtime(SEAT_USAGE_CACHE) : nil
    return if mtime && (Time.now - mtime) <= SEAT_USAGE_STALE

    pid = Process.spawn(
      "timeout", SEAT_USAGE_TIMEOUT.to_s,
      "flock", "-n", SEAT_USAGE_LOCK,
      SEAT_USAGE_BIN, "--quiet",
      in: "/dev/null",
      out: "/dev/null",
      err: "/dev/null"
    )
    Process.detach(pid)
    warn "seat-usage spawned pid=#{pid}"
  rescue StandardError => e
    warn "seat-usage spawn: #{e.message}"
  end

  def read_seat_usage_cache
    return nil unless File.file?(SEAT_USAGE_CACHE)

    parsed = JSON.parse(File.read(SEAT_USAGE_CACHE))
    parsed.is_a?(Hash) ? parsed : nil
  rescue JSON::ParserError, Errno::ENOENT => e
    warn "seat-usage cache: #{e.message}"
    nil
  end

  # One row per bar of a group orderly has no builder for. The label is the
  # group's vendor and the bar's own label. "vendor" sets the row's hue and
  # "subscription" its band and read stamp.
  def row_quota_seats(cache, verified, group)
    head = group["label"].is_a?(String) ? group["label"] : group["id"]
    (group["bars"].is_a?(Array) ? group["bars"] : []).select { |b| b.is_a?(Hash) }.map do |bar|
      sub = bar["seat"].is_a?(String) ? bar["seat"] : group["id"]
      id = bar["pool"].is_a?(String) ? bar["pool"] : "#{sub}_#{bar["name"]}"
      label = "#{head} · #{bar["label"] || bar["name"]}"
      pct = bar["pct"].is_a?(Numeric) ? bar["pct"] : nil
      reset = bar["reset_ts"].is_a?(Numeric) ? iso(Time.at(bar["reset_ts"])) : nil
      window = bar["window_s"].is_a?(Numeric) && bar["window_s"].positive? ? bar["window_s"].round : nil
      row =
        if bar["kind"] == "empty"
          live_quota_seat(seat: id, label: label, percent: 100, text: "exhausted", pace: "",
                          verified: verified, window: [reset, window]).merge("exhausted" => true)
        elsif bar["kind"] == "seat" && pct
          pace = quota_pace(cache, "#{id}_pace")
          live_quota_seat(seat: id, label: label, percent: pct, text: join_text(pct_text(pct), pace_phrase(pace)),
                          pace: pace, verified: verified, window: [reset, window])
        else
          unknown_quota_seat(id, label, verified)
        end
      fams = bar["families"].is_a?(Array) ? bar["families"].select { |f| f.is_a?(String) && !f.empty? } : []
      row.merge("vendor" => head.downcase, "subscription" => sub, "families" => fams)
    end
  end

  # Which seat-usage as_of stamp each rail seat comes from.
  QUOTA_AS_OF = {
    "claude_weekly" => "claude", "claude_fable" => "claude", "codex" => "chatgpt",
    "cursor_models" => "cursor", "cursor_other" => "cursor",
    "grokbot" => "grokbot", "supergrok" => "grok", "muse" => "muse"
  }.freeze

  # seat-usage keeps a seat's last numbers when a read fails and drops its
  # as_of stamp. Without this the rail shows those old numbers as current.
  def quota_read(cache, seat)
    key = QUOTA_AS_OF[seat["seat"]] || seat["subscription"]
    return {} unless key && cache.is_a?(Hash)

    stamp = cache["as_of"].is_a?(Hash) ? cache["as_of"][key] : nil
    if stamp.nil?
      why = cache["errors"].is_a?(Hash) ? cache["errors"][key] : nil
      return { "verified_at" => nil, "read_failed" => true, "read_error" => why }
    end

    { "verified_at" => iso(Time.at(Float(stamp))), "read_failed" => false }
  rescue ArgumentError, TypeError
    { "verified_at" => nil, "read_failed" => true }
  end

  def cache_ts_iso(cache)
    return nil unless cache.is_a?(Hash)

    ts = cache["ts"]
    return nil if ts.nil?

    iso(Time.at(Float(ts)))
  rescue ArgumentError, TypeError
    nil
  end

  def quota_num(cache, key)
    return nil unless cache.is_a?(Hash)

    v = cache[key]
    return v if v.is_a?(Numeric)
    return nil if v.nil? || v == ""

    Float(v)
  rescue ArgumentError, TypeError
    nil
  end

  def quota_str(cache, key)
    return nil unless cache.is_a?(Hash)

    v = cache[key]
    return nil if v.nil?

    s = v.to_s
    s.empty? ? nil : s
  end

  def quota_pace(cache, key)
    code = quota_str(cache, key).to_s
    %w[under on ahead].include?(code) ? code : ""
  end

  def pace_phrase(code)
    case code
    when "on" then "on pace"
    when "ahead" then "ahead of pace"
    when "under" then "under pace"
    else ""
    end
  end

  def join_text(*parts)
    parts.flatten.map { |p| p.to_s }.reject(&:empty?).join(" · ")
  end

  def pct_text(n)
    "#{n.round}%"
  end

  def unknown_quota_seat(seat, label, verified)
    {
      "seat" => seat,
      "label" => label,
      "status" => "unknown",
      "percent" => nil,
      "text" => "unknown",
      "pace" => "",
      "resets_at" => nil,
      "window_s" => nil,
      "verified_at" => verified,
      "note" => "seat-usage has no value"
    }
  end

  # The page shades the elapsed share of the window from these two, as the
  # status line does, so the shading is current between fetches.
  def live_quota_seat(seat:, label:, percent:, text:, pace:, verified:, window: [nil, nil], note: nil)
    {
      "seat" => seat,
      "label" => label,
      "status" => "live",
      "percent" => percent,
      "text" => text,
      "pace" => pace.to_s,
      "resets_at" => window[0],
      "window_s" => window[1],
      "verified_at" => verified,
      "note" => note
    }
  end

  # [resets_at ISO, window seconds] from the cache's *_reset_ts and *_window_s.
  def quota_window(cache, reset_key, window_key = nil, default_s = nil)
    ts = quota_num(cache, reset_key)
    win = window_key ? quota_num(cache, window_key) : nil
    win ||= default_s
    [ts && iso(Time.at(ts)), win && win.positive? ? win.round : nil]
  end

  # rate_limit_tier with the default_ prefix removed. claude_ai is Pro.
  # A Max tier's name contains "max" (default_max, default_claude_max, …).
  CLAUDE_PLAN_TITLES = { "claude_ai" => "Pro" }.freeze

  def claude_plan_tier(cache)
    plan = quota_str(cache, "claude_plan")
    return nil if plan.nil? || plan == "?"

    plan
  end

  def claude_max_plan?(plan)
    plan.to_s.downcase.include?("max")
  end

  def claude_plan_title(plan)
    return nil if plan.nil?
    return "Max" if claude_max_plan?(plan)

    CLAUDE_PLAN_TITLES[plan] || plan
  end

  def claude_seat_label(plan, suffix)
    title = claude_plan_title(plan)
    head = title.nil? ? "Claude" : "Claude #{title}"
    "#{head} · #{suffix}"
  end

  # seat-usage writes fable only from a weekly_scoped limit. A finished Claude
  # read with no such limit, on a plan that is not Max, means the slice is not
  # on the plan. A missing number on Max is still unknown.
  def fable_absent?(cache, plan)
    return false if plan.nil? || claude_max_plan?(plan)
    return false unless cache.is_a?(Hash)

    stamp = cache["as_of"].is_a?(Hash) ? cache["as_of"]["claude"] : nil
    !stamp.nil?
  end

  def absent_fable_seat(plan, label, verified)
    title = claude_plan_title(plan)
    {
      "seat" => "claude_fable",
      "label" => label,
      "status" => "absent",
      "percent" => nil,
      "text" => title ? "not on #{title}" : "not on this plan",
      "pace" => "",
      "resets_at" => nil,
      "window_s" => nil,
      "verified_at" => verified,
      "plan" => plan,
      "note" => "Plan #{plan} was read and has no weekly Fable slice. That slice is on Max."
    }
  end

  def quota_claude_fable(cache, verified)
    plan = claude_plan_tier(cache)
    label = claude_seat_label(plan, "Fable slice")
    pct = quota_num(cache, "fable")
    return absent_fable_seat(plan, label, verified) if pct.nil? && fable_absent?(cache, plan)
    return unknown_quota_seat("claude_fable", label, verified) if pct.nil?

    pace = quota_pace(cache, "fable_pace")
    live_quota_seat(
      seat: "claude_fable",
      label: label,
      percent: pct,
      text: join_text(pct_text(pct), pace_phrase(pace)),
      pace: pace,
      verified: verified,
      window: quota_window(cache, "fable_reset_ts", nil, WEEK_S)
    ).merge("plan" => plan)
  end

  def quota_claude_weekly(cache, verified)
    plan = claude_plan_tier(cache)
    pct = quota_num(cache, "claude_week")
    label = claude_seat_label(plan, "weekly")
    return unknown_quota_seat("claude_weekly", label, verified) if pct.nil?

    pace = quota_pace(cache, "claude_week_pace")
    five = quota_num(cache, "claude_5h")
    five_text = five.nil? ? nil : "5h #{pct_text(five)}"
    # The page reddens the 5h text over pace, so it needs the 5h window too.
    five_reset, five_window = quota_window(cache, "claude_5h_reset_ts", nil, 5 * 60 * 60)
    five_hour = five.nil? ? nil : { "percent" => five, "resets_at" => five_reset, "window_s" => five_window }
    live_quota_seat(
      seat: "claude_weekly",
      label: label,
      percent: pct,
      text: join_text(pct_text(pct), five_text, pace_phrase(pace)),
      pace: pace,
      verified: verified,
      window: quota_window(cache, "claude_week_reset_ts", nil, WEEK_S)
    ).merge("five_hour" => five_hour, "plan" => plan)
  end

  def quota_codex(cache, verified)
    pct = quota_num(cache, "codex")
    label = "Codex · weekly"
    return unknown_quota_seat("codex", label, verified) if pct.nil?

    pace = quota_pace(cache, "codex_pace")
    age = quota_num(cache, "codex_age_h")
    # seat-usage reads Codex live now; its age matters only once it falls back
    # to a rollout file that is at least an hour old.
    age_text = age.nil? || age < 1 ? nil : "as of #{age}h ago"
    # Plus adds a 5h window beside the weekly one; Pro has none.
    five = quota_num(cache, "codex_5h")
    five_text = five.nil? ? nil : "5h #{pct_text(five)}"
    five_reset, five_window = quota_window(cache, "codex_5h_reset_ts", nil, 5 * 60 * 60)
    five_hour = five.nil? ? nil : { "percent" => five, "resets_at" => five_reset, "window_s" => five_window }
    live_quota_seat(
      seat: "codex",
      label: label,
      percent: pct,
      text: join_text(pct_text(pct), five_text, pace_phrase(pace), age_text),
      pace: pace,
      verified: verified,
      window: quota_window(cache, "codex_reset_ts", "codex_window_s"),
      note: quota_str(cache, "codex_plan")
    ).merge("plan" => quota_str(cache, "codex_plan"), "five_hour" => five_hour)
  end

  def quota_muse(cache, verified)
    pct = quota_num(cache, "muse_week")
    label = "Muse · weekly"
    return unknown_quota_seat("muse", label, verified) if pct.nil?

    five = quota_num(cache, "muse_5h")
    five_text = five.nil? ? nil : "5h #{pct_text(five)}"
    five_reset, five_window = quota_window(cache, "muse_5h_reset_ts", nil, 5 * 60 * 60)
    # Conclave sometimes stores a 5h reset that has already passed. The numbers
    # are still the reading; say so instead of hiding the seat.
    five_passed = five_reset && (Time.parse(five_reset) <= Time.now)
    five_hour = five.nil? ? nil : { "percent" => five, "resets_at" => five_reset, "window_s" => five_window }
    five_text = join_text(five_text, ("5h reset passed" if five_passed))
    live_quota_seat(
      seat: "muse",
      label: label,
      percent: pct,
      text: join_text(pct_text(pct), five_text),
      pace: "",
      verified: verified,
      window: quota_window(cache, "muse_week_reset_ts", nil, WEEK_S)
    ).merge("five_hour" => five_hour)
  end

  def quota_supergrok(cache, verified)
    label = "SuperGrok · weekly"
    window = quota_window(cache, "grok_reset_ts", "grok_window_s")
    if cache.is_a?(Hash) && cache["grok_exhausted"] == true
      h = quota_num(cache, "grok_402_h")
      h_text =
        if h.nil? then nil
        elsif h.to_f < 0.1 then "402 just now"
        else "402 #{h}h ago"
        end
      return live_quota_seat(
        seat: "supergrok",
        label: label,
        percent: 100,
        text: join_text("exhausted", h_text),
        pace: "",
        verified: verified,
        window: window
      ).merge("exhausted" => true)
    end
    # The weekly pool, read by seat-usage from grok.com/rest/grok/credits with
    # the browser cookie.
    pct = quota_num(cache, "grok_pct")
    unless pct.nil?
      pace = quota_pace(cache, "grok_pace")
      return live_quota_seat(
        seat: "supergrok",
        label: label,
        percent: pct,
        text: join_text(pct_text(pct), pace_phrase(pace)),
        pace: pace,
        verified: verified,
        window: window
      )
    end

    note = cache.is_a?(Hash) && cache["grok_cookie_ok"] == false ? "seat-usage needs the grok web cookie" : nil
    seat = unknown_quota_seat("supergrok", label, verified)
    seat["note"] = note if note
    seat
  end

  # One seat per Cursor dashboard bar. cursor_pct is the higher of the two,
  # which hid Grok work on Cursor Models while Other Models led.
  def quota_cursor(cache, verified, seat, key, name)
    plan = quota_str(cache, "cursor")
    label = plan ? "Cursor #{plan} · #{name}" : "Cursor · #{name}"
    pct = quota_num(cache, "#{key}_pct")
    return unknown_quota_seat(seat, label, verified) if pct.nil?

    pace = quota_pace(cache, "#{key}_pace")
    live_quota_seat(
      seat: seat,
      label: label,
      percent: pct,
      text: join_text(pct_text(pct), pace_phrase(pace)),
      pace: pace,
      verified: verified,
      window: quota_window(cache, "cursor_reset_ts", "cursor_window_s")
    ).merge("on_demand" => quota_on_demand(cache))
  end

  # Cursor's on-demand spend this cycle in dollars, apart from both bars.
  # limit is nil when seat-usage has not recorded one.
  def quota_on_demand(cache)
    spent = quota_num(cache, "cursor_ondemand")
    spent && { "spent" => spent, "limit" => quota_num(cache, "cursor_ondemand_limit") }
  end

  # The Grok Bot's weekly allowance. Cursor bills it, but it is on neither
  # Cursor dashboard bar. Past it the Bot bills Cursor on-demand.
  def quota_grokbot(cache, verified)
    label = "Grok Bot · weekly"
    pct = quota_num(cache, "bot_pct")
    return unknown_quota_seat("grokbot", label, verified) if pct.nil?

    window = quota_window(cache, "bot_reset_ts", "bot_window_s")
    if cache["bot_exhausted"] == true
      return live_quota_seat(
        seat: "grokbot", label: label, percent: 100, text: "exhausted",
        pace: "", verified: verified, window: window
      ).merge("exhausted" => true, "on_demand" => quota_on_demand(cache))
    end

    pace = quota_pace(cache, "bot_pace")
    live_quota_seat(
      seat: "grokbot",
      label: label,
      percent: pct,
      text: join_text(pct_text(pct), pace_phrase(pace)),
      pace: pace,
      verified: verified,
      window: window
    ).merge("on_demand" => quota_on_demand(cache))
  end

  def linear_graphql(key, query = LINEAR_QUERY)
    uri = URI(LINEAR_URL)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.open_timeout = 10
    http.read_timeout = 10
    req = Net::HTTP::Post.new(uri.request_uri)
    req["Authorization"] = key
    req["Content-Type"] = "application/json"
    req.body = JSON.generate({ "query" => query })
    res = http.request(req)
    raise "linear http #{res.code}" unless res.is_a?(Net::HTTPSuccess)

    parsed = JSON.parse(res.body)
    errors = parsed["errors"]
    if errors.is_a?(Array) && errors.any? && parsed["data"].nil?
      raise "linear graphql: #{errors.map { |e| e["message"] }.join("; ")}"
    end
    if errors.is_a?(Array) && errors.any?
      warn "linear graphql partial errors: #{errors.map { |e| e["message"] }.join("; ")}"
    end
    parsed
  end

  def last_linear_mentions
    @mutex.synchronize do
      rows = source_data("linear").is_a?(Hash) ? source_data("linear")["mentions"] : nil
      rows.is_a?(Array) ? rows.map { |row| row.dup } : []
    end
  end

  def fetch_linear_mentions_safe(key, viewer_id)
    @linear_mentions_error = nil
    fetch_linear_mentions(key, viewer_id)
  rescue StandardError => e
    @linear_mentions_error = e.message
    warn "remote linear mentions: #{e.message}"
    last_linear_mentions
  end

  def fetch_linear_mentions(key, viewer_id)
    parsed = linear_graphql(key, LINEAR_NOTIF_QUERY)
    viewer_id = parsed.dig("data", "viewer", "id") || viewer_id
    nodes = parsed.dig("data", "notifications", "nodes")
    nodes = [] unless nodes.is_a?(Array)
    cutoff = utc_now - LINEAR_NOTIF_MAX_AGE
    newest = {}
    nodes.each do |node|
      next unless node.is_a?(Hash)
      next unless LINEAR_NOTIF_TYPES.include?(node["type"].to_s)

      created = parse_time(node["createdAt"])
      next if created.nil? || created < cutoff

      actor = node["actor"]
      next unless actor.is_a?(Hash)
      next if viewer_id && actor["id"].to_s == viewer_id.to_s

      issue = node["issue"]
      next unless issue.is_a?(Hash) && !issue["id"].to_s.empty?

      prev = newest[issue["id"]]
      if prev.nil? || node["createdAt"].to_s > prev["createdAt"].to_s
        newest[issue["id"]] = node
      end
    end
    selected = newest.values.sort_by { |n| n["createdAt"].to_s }.reverse.first(LINEAR_ANSWERED_LIMIT)
    answered = linear_answered_issue_ids(key, viewer_id, selected)
    mentions = selected.filter_map do |node|
      issue_id = node.dig("issue", "id")
      next if answered.include?(issue_id)

      shape_linear_mention(node)
    end
    mentions.sort_by { |m| m["at"].to_s }.reverse
  end

  def linear_answered_issue_ids(key, viewer_id, nodes)
    return [] if nodes.empty?

    aliases = nodes.each_with_index.map do |node, i|
      uuid = node.dig("issue", "id")
      %(i#{i}: issue(id: "#{gql_escape(uuid)}") { comments(last: 10) { nodes { createdAt user { id } } } })
    end
    parsed = linear_graphql(key, "{ #{aliases.join("\n")} }")
    data = parsed["data"]
    raise "linear graphql: no issue comments" unless data.is_a?(Hash)

    answered = []
    nodes.each_with_index do |node, i|
      comments = data.dig("i#{i}", "comments", "nodes")
      comments = [] unless comments.is_a?(Array)
      threshold = node.dig("comment", "createdAt") || node["createdAt"]
      next if threshold.nil? || viewer_id.nil? || viewer_id.to_s.empty?
      next unless comments.any? { |c| linear_viewer_replied_after?(c, viewer_id, threshold) }

      answered << node.dig("issue", "id")
    end
    answered
  end

  def linear_viewer_replied_after?(comment, viewer_id, threshold)
    return false unless comment.is_a?(Hash)
    return false unless comment.dig("user", "id").to_s == viewer_id.to_s

    later = parse_time(comment["createdAt"])
    base = parse_time(threshold)
    later && base && later > base
  end

  def shape_linear_mention(node)
    issue = node["issue"] || {}
    comment = node["comment"]
    comment = nil unless comment.is_a?(Hash)
    actor = node["actor"]
    kind = LINEAR_MENTION_TYPES.include?(node["type"].to_s) ? "mention" : "comment"
    at = iso((comment && comment["createdAt"]) || node["createdAt"])
    {
      "issue_id" => issue["identifier"].to_s,
      "title" => issue["title"],
      "url" => issue["url"],
      "assignee" => display_name(issue["assignee"]),
      "state" => issue.dig("state", "name"),
      "kind" => kind,
      "actor" => display_name(actor),
      "comment_url" => mention_comment_url(issue["url"], comment),
      "excerpt" => comment ? one_line_excerpt(comment["body"], 140) : nil,
      "at" => at
    }
  end

  def mention_comment_url(issue_url, comment)
    return comment["url"] if comment.is_a?(Hash) && !comment["url"].to_s.empty?
    if comment.is_a?(Hash) && !comment["id"].to_s.empty? && !issue_url.to_s.empty?
      short = comment["id"].to_s.split("-").first
      return "#{issue_url}#comment-#{short}"
    end
    issue_url
  end

  def display_name(user)
    return nil unless user.is_a?(Hash)

    name = user["displayName"].to_s.strip
    name.empty? ? nil : name
  end

  def shape_linear_row(issue, viewer_id)
    ident = issue["identifier"].to_s
    labels = (issue.dig("labels", "nodes") || []).map { |n| n["name"] }.compact
    comment = (issue.dig("comments", "nodes") || []).last
    comment = nil unless comment.is_a?(Hash)
    user = comment && comment["user"]
    user = nil unless user.is_a?(Hash)
    last_at = comment && iso(comment["createdAt"])
    excerpt = comment ? one_line_excerpt(comment["body"]) : nil
    state_name = issue.dig("state", "name")
    state_type = issue.dig("state", "type")
    updated = iso(issue["updatedAt"]) || issue["updatedAt"]
    {
      "id" => ident,
      "title" => issue["title"],
      "url" => issue["url"],
      "team" => issue.dig("team", "key"),
      "state" => state_name,
      "state_type" => state_type,
      "priority" => issue["priority"],
      "labels" => labels,
      "last_comment_by" => commenter_name(user),
      "last_comment_at" => last_at,
      "last_comment_mine" => !!(user && viewer_id && user["id"] == viewer_id),
      "last_comment_excerpt" => excerpt,
      "updated_at" => updated
    }
  end

  def commenter_name(user)
    return nil unless user.is_a?(Hash)

    name = user["displayName"].to_s.strip
    name = user["name"].to_s.strip if name.empty?
    name.empty? ? nil : name
  end

  def one_line_excerpt(body, limit = 120)
    text = body.to_s.gsub(/[\r\n]+/, " ").gsub(/[ \t]+/, " ").strip
    return nil if text.empty?

    text.length > limit ? text[0, limit] : text
  end

  # A plain substring lets a short id claim a longer ticket's worktree:
  # ABC-643 matched abc-6432-some-feature. Require the id to end on a
  # non-digit boundary so only the ticket it names matches.
  def ident_pattern(ident)
    needle = ident.to_s.downcase
    return nil if needle.empty?

    /(?<![a-z0-9])#{Regexp.escape(needle)}(?!\d)/
  end

  def matching_worktree_names(ident, wt_rows)
    pattern = ident_pattern(ident)
    return [] if pattern.nil?

    wt_rows.filter_map do |row|
      name = row["name"].to_s
      name if name.downcase.match?(pattern)
    end
  end

  def first_active_agent(ident, wt_rows)
    pattern = ident_pattern(ident)
    return nil if pattern.nil?

    wt_rows.each do |row|
      next unless row["name"].to_s.downcase.match?(pattern)

      (row["agents"] || []).each do |agent|
        state = agent["state"].to_s
        next if state.empty? || state == "idle"

        tool = agent["tool"].to_s
        next if tool.empty?

        return "#{tool} · #{state}"
      end
    end
    nil
  end

  def linear_group(state_name, state_type, labels, worktrees)
    if waiting_state?(state_name)
      "waiting"
    elsif state_type.to_s == "started"
      "in_progress"
    elsif refined_label?(labels) && worktrees.empty?
      "next_up"
    else
      "other"
    end
  end

  def waiting_state?(name)
    WAITING_STATES.include?(norm_label(name))
  end

  def refined_label?(labels)
    return false if NEXT_UP_LABEL.empty?

    needle = norm_label(NEXT_UP_LABEL)
    labels.any? { |n| norm_label(n) == needle }
  end

  def norm_label(value)
    value.to_s.downcase.gsub(/\s+/, " ").strip
  end

  def gh_search_prs(filter, json_fields, extra: [])
    stdout, stderr, status = run_cmd(
      "gh", "search", "prs", filter, "--state=open",
      "--limit", SEARCH_LIMIT.to_s,
      *extra,
      "--json", json_fields,
      timeout: 60
    )
    raise "gh search prs #{filter}: #{stderr.strip}" unless status.success?

    parsed = JSON.parse(stdout)
    parsed.is_a?(Array) ? parsed : []
  end

  def pr_search_key(hit)
    nwo = hit.dig("repository", "nameWithOwner").to_s
    num = hit["number"]
    return nil if nwo.empty? || num.nil?

    "#{nwo}##{num}"
  end

  def gql_escape(str)
    # gsub's string replacement reads "\\\\" as one literal backslash, so the
    # two-pass form left backslashes unescaped. The block form does not.
    str.to_s.gsub(/[\\"]/) { |c| "\\#{c}" }
  end

  def graphql_pr_details(hits)
    aliases = []
    hits.each_with_index do |hit, i|
      nwo = hit.dig("repository", "nameWithOwner").to_s
      owner, name = nwo.split("/", 2)
      next if owner.nil? || name.nil?

      aliases << %(pr#{i}: repository(owner:"#{gql_escape(owner)}", name:"#{gql_escape(name)}"){ pullRequest(number: #{hit["number"].to_i}) {\n#{PR_GQL_FIELDS}      } })
    end
    query = "query {\n#{aliases.join("\n")}\n  rateLimit { cost remaining limit nodeCount }\n}"
    payload = JSON.generate({ "query" => query })
    stdout, stderr, status = run_cmd(
      "gh", "api", "graphql", "--input", "-",
      timeout: 120,
      stdin_data: payload
    )
    raise "gh api graphql: #{stderr.strip}" unless status.success?

    parsed = JSON.parse(stdout)
    if parsed["errors"].is_a?(Array) && parsed["errors"].any? && parsed["data"].nil?
      raise "gh api graphql: #{parsed["errors"].map { |e| e["message"] }.join("; ")}"
    end
    if parsed["errors"].is_a?(Array) && parsed["errors"].any?
      warn "prs graphql partial errors: #{parsed["errors"].map { |e| e["message"] }.join("; ")}"
    end
    data = parsed["data"] || {}
    rl = data["rateLimit"]
    warn "prs graphql rateLimit=#{rl.inspect}" if rl
    out = {}
    hits.each_with_index do |hit, i|
      node = data.dig("pr#{i}", "pullRequest")
      out[pr_search_key(hit)] = node if node
    end
    out
  end

  def shape_pr_row(hit, gql, tab)
    repo = hit.dig("repository", "name").to_s
    author = gql&.dig("author", "login") || hit.dig("author", "login")
    author = ME_LOGIN if author.nil? && tab == :mine
    created = gql && gql["createdAt"] || hit["createdAt"]
    updated = gql && gql["updatedAt"] || hit["updatedAt"]
    draft = if gql && !gql["isDraft"].nil?
      gql["isDraft"] ? true : false
    else
      hit["isDraft"] ? true : false
    end
    ci, ci_url, ci_failed_name, ci_failed_at = ci_from_gql(gql)
    threads = thread_stats(gql)
    reviews = review_stats(gql)
    requested = requested_reviewers(gql)
    reviews_known, reviews_empty = reviews_presence(gql)
    decision = gql && gql["reviewDecision"]
    row = {
      "number" => hit["number"],
      "repo" => repo,
      "title" => (gql && gql["title"]) || hit["title"],
      "url" => (gql && gql["url"]) || hit["url"],
      "draft" => draft,
      "author" => author,
      "ci" => ci,
      "ci_url" => ci_url,
      "ci_failed_name" => ci_failed_name,
      "ci_failed_at" => ci_failed_at,
      "review_decision" => decision,
      "threads_open" => threads[:open],
      "threads_awaiting_me" => threads[:awaiting],
      "threads_last_by" => threads[:last_by],
      "thread_comment_url" => threads[:comment_url],
      "thread_comment_at" => threads[:awaiting_at],
      "reviews" => reviews[:count],
      "requested_reviewers" => requested,
      "changes_requested_by" => reviews[:changes_by],
      "changes_requested_at" => reviews[:changes_at],
      "created_at" => created,
      "updated_at" => updated,
      # The search hit alone says nothing about CI, threads or reviews. Without
      # the GraphQL node those fields are defaults, not findings, so the row
      # says so rather than rendering as a healthy PR.
      "details" => gql.nil? ? "unknown" : "ok",
      # Kept for needs-you. The PR card does not draw these.
      "team_reviewers" => team_reviewers_from(gql),
      "team_requested" => team_review_requested?(gql),
      "direct_review" => direct_review_requested?(gql),
      "labels" => label_names(gql),
      "reviews_known" => reviews_known,
      "reviews_empty" => reviews_empty,
      "head_oid" => head_oid_from(gql),
      "issue_comment_url" => issue_comment_url_from(gql),
      "latest_thread_comment_url" => latest_thread_comment_url(gql),
      "viewer_is_author" => me?(author)
    }
    if tab == :mine
      group, since = group_mine(row, threads, reviews)
      row["group"] = group
      row["since"] = since
      row["requested_by"] = nil
      row["requested_at"] = nil
      row["ready_at"] = nil
    else
      requested_at, ready_at = review_request_times(gql)
      since, = pick_review_since(requested_at, ready_at, updated, created)
      row["group"] = nil
      row["requested_by"] = author
      row["requested_at"] = requested_at
      row["ready_at"] = ready_at
      row["since"] = since
    end
    row
  end

  def ci_from_gql(gql)
    rollup = gql&.dig("commits", "nodes", 0, "commit", "statusCheckRollup")
    return ["none", nil, nil, nil] if rollup.nil?

    state = rollup["state"].to_s
    ci =
      case state
      when "SUCCESS" then "pass"
      when "FAILURE", "ERROR" then "fail"
      when "PENDING", "EXPECTED" then "pending"
      else "none"
      end
    contexts = rollup.dig("contexts", "nodes") || []
    failed = contexts.select { |c| check_failed?(c) }
    first = failed.first
    ci_url = first && (first["detailsUrl"] || first["targetUrl"])
    ci_name = first && (first["name"] || first["context"])
    newest_at = failed.map { |c| c["completedAt"] }.compact.max
    [ci, ci_url, ci_name, newest_at]
  end

  def check_failed?(node)
    return false unless node.is_a?(Hash)

    if node.key?("conclusion")
      CHECK_FAIL_CONCLUSIONS.include?(node["conclusion"].to_s)
    elsif node.key?("state")
      STATUS_FAIL_STATES.include?(node["state"].to_s)
    else
      false
    end
  end

  def thread_stats(gql)
    nodes = gql&.dig("reviewThreads", "nodes") || []
    open_comments = []
    awaiting = []
    mine_last = []
    nodes.each do |thread|
      next if thread["isResolved"]

      comment = (thread.dig("comments", "nodes") || []).last
      next unless comment.is_a?(Hash)

      open_comments << comment
      login = comment.dig("author", "login")
      if me?(login)
        mine_last << comment["createdAt"]
      else
        awaiting << comment
      end
    end
    last_await = awaiting.max_by { |c| c["createdAt"].to_s }
    last_open = open_comments.max_by { |c| c["createdAt"].to_s }
    {
      open: open_comments.size,
      awaiting: awaiting.size,
      last_by: (last_await || last_open)&.dig("author", "login"),
      comment_url: last_await&.[]("url"),
      awaiting_at: last_await&.[]("createdAt"),
      mine_last_at: mine_last.compact.max
    }
  end

  def review_stats(gql)
    nodes = gql&.dig("latestReviews", "nodes") || []
    newest = nodes.max_by { |r| r["submittedAt"].to_s }
    changes = nodes.select { |r| r["state"].to_s == "CHANGES_REQUESTED" }
    newest_changes = changes.max_by { |r| r["submittedAt"].to_s }
    {
      count: nodes.size,
      newest_at: newest && newest["submittedAt"],
      changes_by: newest_changes&.dig("author", "login"),
      changes_at: newest_changes && newest_changes["submittedAt"]
    }
  end

  def requested_reviewers(gql)
    nodes = gql&.dig("reviewRequests", "nodes") || []
    logins = nodes.map { |n| n.dig("requestedReviewer", "login") }.compact.uniq
    logins
  end

  def team_reviewers_from(gql)
    nodes = gql&.dig("reviewRequests", "nodes") || []
    nodes.filter_map do |node|
      reviewer = node["requestedReviewer"]
      next unless reviewer.is_a?(Hash) && reviewer["__typename"].to_s == "Team"

      slug = reviewer["slug"].to_s
      next if slug.empty?

      name = reviewer["name"].to_s
      { "slug" => slug, "name" => name.empty? ? slug : name }
    end.uniq { |team| team["slug"] }
  end

  # nil labels means the connection was missing. An empty array is a real
  # empty list. Fail closed treats nil as "do not emit a team-ask row".
  # labels(first:10) is the accepted bound: prototype past the tenth label
  # can be missed, and there is no follow-up query.
  def label_names(gql)
    return nil unless gql.is_a?(Hash) && gql.key?("labels")

    nodes = gql.dig("labels", "nodes")
    return nil unless nodes.is_a?(Array)

    nodes.filter_map { |node| node.is_a?(Hash) ? node["name"].to_s : nil }
  end

  def reviews_presence(gql)
    return [false, false] unless gql.is_a?(Hash) && gql.key?("latestReviews")

    nodes = gql.dig("latestReviews", "nodes")
    return [false, false] unless nodes.is_a?(Array)

    [true, nodes.empty?]
  end

  def head_oid_from(gql)
    oid = gql&.dig("commits", "nodes", 0, "commit", "oid").to_s
    oid.empty? ? nil : oid
  end

  def issue_comment_url_from(gql)
    node = gql&.dig("comments", "nodes", 0)
    return nil unless node.is_a?(Hash)

    url = node["url"].to_s
    url.empty? ? nil : url
  end

  def latest_thread_comment_url(gql)
    nodes = gql&.dig("reviewThreads", "nodes")
    return nil unless nodes.is_a?(Array)

    comments = nodes.filter_map do |thread|
      next unless thread.is_a?(Hash)

      (thread.dig("comments", "nodes") || []).last
    end
    last = comments.max_by { |comment| comment["createdAt"].to_s }
    url = last && last["url"].to_s
    url.nil? || url.empty? ? nil : url
  end

  def team_slugs(pr)
    (pr["team_reviewers"] || []).map { |team| team["slug"].to_s }.reject(&:empty?).uniq.sort
  end

  def team_names(pr, slugs)
    slugs.map do |slug|
      hit = (pr["team_reviewers"] || []).find { |team| team["slug"] == slug }
      name = hit && hit["name"].to_s
      name.nil? || name.empty? ? slug : name
    end
  end

  def github_key(pr, suffix)
    "github:#{pr["repo"]}##{pr["number"]}:#{suffix}"
  end

  # Precise token: oid, latest thread-comment URL, latest issue-comment URL.
  # A missing piece is omitted. updated_at is used only when all three are
  # missing. Team rows also append sorted slugs so a team change is a change.
  def github_review_token(pr, teams: false)
    oid = pr["head_oid"].to_s
    thread = pr["latest_thread_comment_url"].to_s
    issue = pr["issue_comment_url"].to_s
    parts = []
    parts << "oid:#{oid}" unless oid.empty?
    parts << "thread:#{thread}" unless thread.empty?
    parts << "issue:#{issue}" unless issue.empty?
    parts << "updated:#{pr["updated_at"]}" if oid.empty? && thread.empty? && issue.empty?
    parts << "teams:#{team_slugs(pr).join(",")}" if teams
    parts.join("|")
  end

  def ci_change_token(pr)
    name = pr["ci_failed_name"].to_s
    at = pr["ci_failed_at"].to_s
    return "check:#{name}|at:#{at}" if !name.empty? || !at.empty?

    "oid:#{pr["head_oid"]}"
  end

  def stamp_needs_you(row, source:, clear_key:, change_token:, ask_from:, dim: false)
    row["source"] = source
    row["clear_key"] = clear_key
    row["change_token"] = change_token.to_s
    row["ask_from"] = ask_from
    row["dim"] = dim ? true : false
    row["tier"] = needs_you_tier(row)
    row
  end

  def agent_clear_key(session)
    sid = session["id"].to_s
    sid = session["worktree"].to_s if sid.empty?
    sid = session["cwd"].to_s if sid.empty?
    sid = session["tool"].to_s if sid.empty?
    "agent:#{session["tool"]}:#{sid}"
  end

  # verified_at changes on every read. The token is exhausted plus the rounded
  # percent, so a snooze survives the next remote tick while the percent holds.
  def quota_change_token(seat)
    pct = seat["percent"]
    pct_s = pct.is_a?(Numeric) ? pct.round.to_s : ""
    "exhausted:#{seat["exhausted"] ? "true" : "false"}|pct:#{pct_s}"
  end

  # No reviewed_recently_by_me? check on this path. GitHub drops you from
  # reviewRequests the moment you submit a review, so still being named there
  # means someone re-requested you *after* that review. Filtering on the
  # recent review hid exactly the re-request, for a week. The team path below
  # keeps the check, because there you were never individually asked.
  def keep_review_requested?(hit, gql)
    return false unless direct_review_requested?(gql)

    author = gql&.dig("author", "login") || hit.dig("author", "login")
    return false if bot_author?(author)

    true
  end

  def keep_review_requested_team?(hit, gql)
    return false if direct_review_requested?(gql)
    return false unless team_review_requested?(gql)

    author = gql&.dig("author", "login") || hit.dig("author", "login")
    return false if bot_author?(author)
    return false if reviewed_recently_by_me?(gql)

    true
  end

  def direct_review_requested?(gql)
    nodes = gql&.dig("reviewRequests", "nodes") || []
    nodes.any? do |node|
      reviewer = node["requestedReviewer"]
      next false unless reviewer.is_a?(Hash)

      typename = reviewer["__typename"].to_s
      next false unless typename.empty? || typename == "User"

      me?(reviewer["login"])
    end
  end

  def team_review_requested?(gql)
    nodes = gql&.dig("reviewRequests", "nodes") || []
    nodes.any? do |node|
      reviewer = node["requestedReviewer"]
      next false unless reviewer.is_a?(Hash)

      reviewer["__typename"].to_s == "Team"
    end
  end

  def bot_author?(login)
    name = login.to_s.downcase
    return true if name.end_with?("[bot]")

    BOT_AUTHOR_LOGINS.include?(name)
  end

  def reviewed_recently_by_me?(gql)
    updated = parse_time(gql && gql["updatedAt"])
    return false if updated.nil?

    cutoff = updated - REVIEW_RECENT_WINDOW
    nodes = gql&.dig("latestReviews", "nodes") || []
    nodes.any? do |review|
      next false unless me?(review.dig("author", "login"))

      submitted = parse_time(review["submittedAt"])
      submitted && submitted > cutoff
    end
  end

  def me?(login)
    login.to_s.downcase == ME_LOGIN
  end

  def group_mine(row, threads, reviews)
    # ci, threads and reviews are all defaults here, so every branch below
    # would read as an assertion the data does not support.
    return ["unknown", row["updated_at"] || row["created_at"]] if row["details"] == "unknown"

    blocked_me = row["ci"] == "fail" || row["threads_awaiting_me"].positive? || row["review_decision"] == "CHANGES_REQUESTED"
    if blocked_me
      times = []
      times << row["ci_failed_at"] if row["ci"] == "fail"
      times << row["thread_comment_at"] if row["threads_awaiting_me"].positive?
      times << row["changes_requested_at"] if row["review_decision"] == "CHANGES_REQUESTED"
      since = times.compact.max || row["updated_at"]
      return ["blocked_on_me", since]
    end
    mine_last_open = row["threads_open"].positive? && row["threads_awaiting_me"].zero?
    if mine_last_open || row["reviews"].positive? || !row["requested_reviewers"].empty?
      since = threads[:mine_last_at] || reviews[:newest_at] || row["updated_at"]
      return ["blocked_on_them", since]
    end
    ["ready", row["created_at"]]
  end

  def pings_for_port(port, repo)
    cached = @ping_cache[port]
    if cached && cached["at"] && (Time.now - cached["at"]) < PING_INTERVAL
      return cached["pings"]
    end

    paths = PING_PATHS[repo] || %w[/login]
    pings = paths.map { |path| ping_one(port, path) }
    @ping_cache[port] = { "at" => Time.now, "pings" => pings }
    pings
  end

  def ping_one(port, path)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    uri = URI("http://127.0.0.1:#{port}#{path}")
    http = Net::HTTP.new(uri.host, uri.port)
    http.open_timeout = PING_TIMEOUT
    http.read_timeout = PING_TIMEOUT
    http.max_retries = 0
    req = Net::HTTP::Get.new(uri.request_uri)
    res = http.request(req)
    ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
    code = res.code.to_i
    { "path" => path, "ok" => [200, 302].include?(code), "status" => code, "ms" => ms }
  rescue StandardError
    ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
    { "path" => path, "ok" => false, "status" => nil, "ms" => ms }
  end

  def timeline_nodes(gql)
    nodes = gql&.dig("timelineItems", "nodes")
    return [] unless nodes.is_a?(Array)

    nodes.select { |node| node.is_a?(Hash) }
  end

  def latest_timestamp(times)
    times.compact.reject { |t| t.to_s.empty? }.max_by { |t| parse_time(t) || Time.at(0) }
  end

  def user_reviewer?(reviewer)
    typename = reviewer["__typename"].to_s
    typename.empty? || typename == "User"
  end

  # `last:20` on the two event types. Events whose reviewer is missing are
  # ignored: GitHub sometimes leaves requestedReviewer null, and that event
  # cannot be told apart from a request for someone else.
  def latest_review_requested_at(gql, who)
    times = timeline_nodes(gql).filter_map do |node|
      next unless node["__typename"] == "ReviewRequestedEvent"

      reviewer = node["requestedReviewer"]
      next unless reviewer.is_a?(Hash)

      keep = case who
             when :user then user_reviewer?(reviewer) && me?(reviewer["login"])
             when :team then reviewer["__typename"].to_s == "Team"
             else false
             end
      next unless keep

      node["createdAt"]
    end
    latest_timestamp(times)
  end

  def latest_ready_for_review_at(gql)
    times = timeline_nodes(gql).filter_map do |node|
      next unless node["__typename"] == "ReadyForReviewEvent"

      node["createdAt"]
    end
    latest_timestamp(times)
  end

  def review_request_times(gql)
    requested = if direct_review_requested?(gql)
      latest_review_requested_at(gql, :user)
    elsif team_review_requested?(gql)
      latest_review_requested_at(gql, :team)
    end
    [requested, latest_ready_for_review_at(gql)]
  end

  # Request time, then the ready-for-review event, then the PR's last update.
  # Creation time is only used when none of those exist, so opening the PR is
  # not treated as the moment someone asked.
  def pick_review_since(requested_at, ready_at, updated_at, created_at)
    if !requested_at.to_s.empty?
      [requested_at, "review_requested"]
    elsif !ready_at.to_s.empty?
      [ready_at, "ready_for_review"]
    elsif !updated_at.to_s.empty?
      [updated_at, "updated_at"]
    else
      [created_at, "created_at"]
    end
  end

  def pr_needs_you_expired?(row)
    return false unless row["kind"] == "pr"

    # The cap is the PR's last update (`expires_from`), not `since`. `since`
    # is when the review was requested or the PR was marked ready, which would
    # hide a request made today on an older PR and would keep a quiet PR whose
    # request is recent.
    t = parse_time(row["expires_from"] || row["since"])
    return false if t.nil?

    t < (utc_now - NEEDS_YOU_PR_MAX_AGE)
  end

  def grok_unconfirmed_needs_you?(session)
    return true unless session["worktree"].to_s.empty?

    t = session["updated_at"]
    return false if t.nil? || t.to_s.empty?

    Time.parse(t.to_s) >= (utc_now - GROK_NEEDS_YOU_MAX_AGE)
  rescue ArgumentError
    false
  end

  def needs_you_tier(row)
    reason = row["reason"].to_s
    return NEEDS_YOU_REASON_TIER[reason] if NEEDS_YOU_REASON_TIER.key?(reason)

    kind = row["kind"].to_s
    return NEEDS_YOU_KIND_TIER[kind] if NEEDS_YOU_KIND_TIER.key?(kind)

    explicit = row["tier"].to_s
    return explicit if NEEDS_YOU_TIER_ORDER.include?(explicit)

    "informational"
  end

  def needs_you_sort_key(row)
    rank = NEEDS_YOU_TIER_ORDER.index(row["tier"].to_s)
    rank = NEEDS_YOU_TIER_ORDER.length if rank.nil?
    since = row["since"].to_s
    [rank, since.empty? ? "9999" : since]
  end

  def needs_you_adapters
    @needs_you_adapters ||= [
      NeedsYou::GithubAdapter.new(self),
      NeedsYou::LinearAdapter.new(self),
      NeedsYou::AgentAdapter.new(self),
      NeedsYou::MachineAdapter.new(self),
      NeedsYou::QuotaAdapter.new(self),
      NeedsYou::SlackAdapter.new
    ]
  end

  def build_needs_you(sessions, prs, linear, quota, wt_rows, machines)
    ctx = NeedsYou::MemoryContext.new(
      snapshots: {
        "prs" => prs,
        "linear" => linear,
        "quota" => quota,
        "machines" => machines,
        "local" => sessions.nil? ? nil : { "sessions" => sessions },
        "slack" => nil
      },
      worktrees: wt_rows || []
    )
    rows = needs_you_adapters.flat_map { |adapter| adapter.fetch(ctx) }
    rows.reject! { |r| pr_needs_you_expired?(r) }
    rows.each { |r| r["tier"] = needs_you_tier(r) }
    rows.sort_by! { |r| needs_you_sort_key(r) }
    rows
  end

  # Prefer a fresh bot link. Heartbeat is host evidence and never stands in for
  # the link. Only expected-always-on machines (Surface, BLD) can add a row:
  #   1. effective link disconnected → row (heartbeat ignored)
  #   2. else effective link unknown AND heartbeat dead (>= 12 min) → row
  # A missing heartbeat is unknown, not dead, so a host this machine cannot
  # see stays quiet. mba / omarchy are not expected always-on.
  def needs_you_from_machines(machines)
    return [] unless machines.is_a?(Hash)

    (machines["machines"] || []).filter_map do |machine|
      next unless machine["expected_always_on"]

      label = machine["label"].to_s
      mid = machine["id"].to_s
      mid = label if mid.empty?
      if machine["link"] == "disconnected"
        stamp_needs_you(
          {
            "kind" => "machine",
            "reason" => "machine_link",
            "id" => label,
            "title" => "#{label} bot link disconnected",
            "detail" => "Grok Bot link is disconnected",
            "since" => machine["link_as_of"],
            "action" => "Grok Bot",
            "worktree" => nil
          },
          source: "machine",
          clear_key: "machine:#{mid}:link",
          change_token: machine["link"].to_s,
          ask_from: nil
        )
      elsif machine["link"] == "unknown" && machine["heartbeat"] == "dead"
        stamp_needs_you(
          {
            "kind" => "machine",
            "reason" => "machine_heartbeat",
            "id" => label,
            "title" => "#{label} heartbeat stale, bot link unknown",
            "detail" => "Host heartbeat is #{HEARTBEAT_LIVE_S / 60}m or older, and the bot link is unknown",
            "since" => machine["heartbeat_last"],
            "action" => "Grok Bot",
            "worktree" => nil
          },
          source: "machine",
          clear_key: "machine:#{mid}:heartbeat",
          change_token: machine["heartbeat"].to_s,
          ask_from: nil
        )
      end
    end
  end

  def needs_you_from_agents(sessions)
    rows = []
    sessions.each do |s|
      if s["tool"] == "grok" && s["state"] == "unconfirmed"
        next unless grok_unconfirmed_needs_you?(s)

        wt = s["worktree"] || File.basename(s["cwd"].to_s)
        rows << stamp_needs_you(
          {
            "kind" => "agent",
            "reason" => "agent_exited",
            "id" => "grok",
            "title" => "Process in #{wt} exited without a completed turn_ended",
            "detail" => s["detail"],
            "since" => s["updated_at"],
            "action" => "grok -c",
            "worktree" => s["worktree"]
          },
          source: "agent",
          clear_key: agent_clear_key(s),
          change_token: s["state"].to_s,
          ask_from: nil
        )
      elsif s["tool"] == "claude" && s["state"] == "waiting"
        wt = s["worktree"] || File.basename(s["cwd"].to_s)
        rows << stamp_needs_you(
          {
            "kind" => "agent",
            "reason" => "permission",
            "id" => "claude",
            "title" => "#{wt} is waiting on a permission prompt",
            "detail" => s["detail"],
            "since" => s["updated_at"],
            "action" => "focus",
            "worktree" => s["worktree"]
          },
          source: "agent",
          clear_key: agent_clear_key(s),
          change_token: s["state"].to_s,
          ask_from: nil
        )
      end
    end
    rows
  end

  def needs_you_from_linear(linear, wt_rows)
    return [] unless linear.is_a?(Hash)

    rows = []
    mention_ids = {}
    (linear["mentions"] || []).each do |mention|
      ident = mention["issue_id"].to_s
      next if ident.empty?

      mention_ids[ident] = true
      actor = mention["actor"].to_s
      verb = mention["kind"] == "mention" ? "mentioned you in" : "commented on"
      rows << stamp_needs_you(
        {
          "kind" => "linear",
          "reason" => "linear_mention",
          "id" => ident,
          "title" => "#{actor} #{verb} #{ident}",
          "detail" => mention["excerpt"],
          "since" => mention["at"],
          "action" => "reply",
          "action_url" => mention["comment_url"],
          "worktree" => matching_worktree_names(ident, wt_rows).first
        },
        source: "linear",
        clear_key: "linear:#{ident}:mention",
        change_token: mention["comment_url"].to_s,
        ask_from: nil
      )
    end
    (linear["mine"] || []).each do |issue|
      next if mention_ids[issue["id"].to_s]
      next unless issue["group"] == "waiting"
      next if issue["last_comment_mine"]
      next if issue["last_comment_by"].to_s.empty?

      excerpt = issue["last_comment_excerpt"].to_s
      rows << stamp_needs_you(
        {
          "kind" => "linear",
          "reason" => "linear_question",
          "id" => issue["id"],
          "title" => "#{issue["last_comment_by"]} asked a question in #{issue["state"]}",
          "detail" => "\"#{excerpt}\"",
          "since" => issue["last_comment_at"],
          "action" => "reply",
          "action_url" => issue["url"],
          "worktree" => (issue["worktrees"] || []).first
        },
        source: "linear",
        clear_key: "linear:#{issue["id"]}:question",
        change_token: "at:#{issue["last_comment_at"]}",
        ask_from: nil
      )
    end
    rows
  end

  # Set not to renew and past its paid-through date: the pool is gone, so its
  # usage asks nothing of anyone. A date-only term lasts through that Pacific
  # calendar day; its timestamp is only the day's start.
  def sub_ended?(seat, now = Time.now)
    return false unless seat["renews"] == false

    term_past?(seat, now)
  end

  def term_past?(seat, now = Time.now)
    on = seat["renews_on"]
    if seat["renews_date_only"] && on.is_a?(String) && on.match?(/\A\d{4}-\d{2}-\d{2}\z/)
      return pacific_ymd(now) > on
    end
    return false unless seat["renews_at"]

    Time.parse(seat["renews_at"]) <= now
  rescue ArgumentError
    false
  end

  def pacific_ymd(time)
    out, status = Open3.capture2({ "TZ" => "America/Los_Angeles" }, "date", "-d", "@#{time.to_i}", "+%F")
    day = out.to_s.strip
    return day if status&.success? && day.match?(/\A\d{4}-\d{2}-\d{2}\z/)

    time.utc.strftime("%Y-%m-%d")
  end

  def needs_you_from_quota(quota)
    return [] unless quota.is_a?(Hash)

    rows = []
    (quota["seats"] || []).each do |seat|
      next unless seat["status"] == "live"
      next if sub_ended?(seat)

      spec = QUOTA_SEATS.find { |s| s["seat"] == seat["seat"] } || {}
      id = seat["label"].to_s.split("·").first.to_s.strip
      # SuperGrok's exhausted flag covers both a 402 since the weekly reset and
      # the weekly pool at 100 percent. The Bot's is hasAvailableUsage false.
      if seat["exhausted"]
        detail = seat["text"].to_s.sub(/\Aexhausted\s*(·\s*)?/, "")
        rows << stamp_needs_you(
          {
            "kind" => "quota",
            "reason" => "quota",
            "id" => id,
            "title" => "#{id} exhausted",
            "detail" => detail,
            "since" => seat["verified_at"],
            "action" => spec["action"] || "/usage",
            "worktree" => nil
          },
          source: "quota",
          clear_key: "quota:#{seat["seat"]}",
          change_token: quota_change_token(seat),
          ask_from: nil
        )
        next
      end

      pct = seat["percent"]
      next unless pct.is_a?(Numeric) && pct >= QUOTA_NEEDS_YOU_AT

      n = pct.round
      rows << stamp_needs_you(
        {
          "kind" => "quota",
          "reason" => "quota",
          "id" => id,
          "title" => "#{seat["label"]} at #{n}%",
          "detail" => seat["text"],
          "since" => seat["verified_at"],
          "action" => spec["action"] || "/usage",
          "worktree" => nil
        },
        source: "quota",
        clear_key: "quota:#{seat["seat"]}",
        change_token: quota_change_token(seat),
        ask_from: nil
      )
    end
    rows
  end

  def needs_you_from_prs(prs, wt_rows)
    return [] unless prs.is_a?(Hash)

    rows = []
    (prs["mine"] || []).each { |pr| rows.concat(needs_you_mine(pr, wt_rows)) }
    (prs["review_requested"] || []).each { |pr| rows.concat(needs_you_review(pr, wt_rows)) }
    # Not review_requested_team: that list is the card's capped group.
    (prs["team_ask_candidates"] || []).each { |pr| rows.concat(needs_you_team(pr, wt_rows)) }
    rows
  end

  def worktree_for_pr(pr, wt_rows)
    num = pr["number"].to_i
    repo = pr["repo"]
    hit = wt_rows.find { |r| r.dig("pr", "number").to_i == num && r["repo"] == repo }
    hit ||= wt_rows.find { |r| r.dig("pr", "number").to_i == num }
    hit && hit["name"]
  end

  def needs_you_mine(pr, wt_rows)
    rows = []
    wt = worktree_for_pr(pr, wt_rows)
    id = "##{pr["number"]}"
    if pr["ci"] == "fail"
      detail = [pr["ci_failed_name"], pr["title"]].compact.reject { |s| s.to_s.empty? }.join(" · ")
      rows << stamp_needs_you(
        {
          "kind" => "pr",
          "reason" => "ci_failed",
          "id" => id,
          "title" => "CI failed on the last push",
          "detail" => detail,
          "since" => pr["ci_failed_at"] || pr["since"],
          "action" => "logs",
          "action_url" => pr["ci_url"],
          "worktree" => wt
        },
        source: "github",
        clear_key: github_key(pr, "ci"),
        change_token: ci_change_token(pr),
        ask_from: nil
      )
    end
    awaiting = pr["threads_awaiting_me"].to_i
    if awaiting.positive?
      who = pr["threads_last_by"] || "reviewer"
      noun = awaiting == 1 ? "thread" : "threads"
      rows << stamp_needs_you(
        {
          "kind" => "pr",
          "reason" => "review_thread",
          "id" => id,
          "title" => "#{awaiting} review #{noun} from #{who} with no reply",
          "detail" => pr["title"],
          "since" => pr["thread_comment_at"] || pr["since"],
          "action" => "reply",
          "action_url" => pr["thread_comment_url"],
          "worktree" => wt
        },
        source: "github",
        clear_key: github_key(pr, "threads"),
        change_token: pr["thread_comment_url"].to_s,
        ask_from: nil
      )
    end
    if pr["review_decision"] == "CHANGES_REQUESTED"
      who = pr["changes_requested_by"] || "reviewer"
      rows << stamp_needs_you(
        {
          "kind" => "pr",
          "reason" => "changes_requested",
          "id" => id,
          "title" => "#{who} requested changes",
          "detail" => pr["title"],
          "since" => pr["changes_requested_at"] || pr["since"],
          "action" => "open",
          "action_url" => pr["url"],
          "worktree" => wt
        },
        source: "github",
        clear_key: github_key(pr, "changes"),
        change_token: "at:#{pr["changes_requested_at"]}",
        ask_from: nil
      )
    end
    rows
  end

  def needs_you_review(pr, wt_rows)
    return [] if pr["draft"]

    # The hour of grace starts when the review was requested, or when the PR
    # was marked ready if that is the only event we have. Creation time is the
    # last resort, so a missing timeline does not restart the hour.
    t = pr["requested_at"] || pr["ready_at"] || pr["created_at"]
    return [] if t.nil? || t.to_s.empty?
    return [] unless Time.parse(t.to_s) <= (utc_now - REVIEW_REQUEST_GRACE)

    since = pr["since"]
    since = t if since.nil? || since.to_s.empty?
    [stamp_needs_you(
      {
        "kind" => "pr",
        "reason" => "review_request",
        "id" => "##{pr["number"]}",
        "title" => "#{pr["requested_by"] || pr["author"] || "someone"} asked for your review",
        "detail" => pr["title"],
        "since" => since,
        # 14 days from the last update. Do not substitute the request-time
        # `since`: that would expire a review asked for today on an old PR, and
        # would keep a PR that has been quiet for two weeks.
        "expires_from" => pr["updated_at"] || pr["created_at"] || t,
        "action" => "review",
        "action_url" => pr["url"],
        "worktree" => worktree_for_pr(pr, wt_rows)
      },
      source: "github",
      clear_key: github_key(pr, "review"),
      change_token: github_review_token(pr),
      ask_from: "direct"
    )]
  rescue ArgumentError
    []
  end

  # Fail closed. Missing labels, missing updated_at, or unknown review data
  # emits nothing. No hour of grace: a team ask shows as soon as the snapshot
  # has it. One row per pull request, named with every requesting team.
  def team_ask_visible?(pr)
    return false unless pr.is_a?(Hash)
    return false unless pr["direct_review"] == false
    return false unless pr["team_requested"] == true
    return false if team_slugs(pr).empty?
    return false if bot_author?(pr["author"])
    return false if pr["viewer_is_author"] || me?(pr["author"])
    return false unless pr["draft"] == false

    labels = pr["labels"]
    return false unless labels.is_a?(Array)
    return false if labels.any? { |name| norm_label(name) == "prototype" }

    updated = parse_time(pr["updated_at"])
    return false if updated.nil?
    return false if updated < (utc_now - TEAM_ASK_MAX_AGE)
    return false unless pr["reviews_empty"] == true

    true
  end

  def needs_you_team(pr, wt_rows)
    return [] unless team_ask_visible?(pr)

    slugs = team_slugs(pr)
    names = team_names(pr, slugs)
    since = pr["since"]
    since = pr["updated_at"] if since.nil? || since.to_s.empty?
    [stamp_needs_you(
      {
        "kind" => "pr",
        "reason" => "team_ask",
        "id" => "##{pr["number"]}",
        "title" => "#{names.join(", ")} asked for a review",
        "detail" => pr["title"],
        "since" => since,
        "expires_from" => pr["updated_at"],
        "action" => "review",
        "action_url" => pr["url"],
        "worktree" => worktree_for_pr(pr, wt_rows)
      },
      source: "github",
      clear_key: github_key(pr, "team"),
      change_token: github_review_token(pr, teams: true),
      ask_from: slugs.join(","),
      dim: true
    )]
  end

  # --- compose ------------------------------------------------------------
  # The cards are built here, from sources, on the way out. Nothing derived
  # is ever written back into a source, so no source can carry a stale join and
  # no patcher is needed to correct one.

  def compose_cards
    local = source("local")
    rows = compose_worktree_rows(local["data"], source_data("pings"))
    sessions = local_sessions(local["data"])
    linear = compose_linear(source_data("linear"), rows)
    prs = source_data("prs")
    quota = source_data("quota")
    machines = source_data("machines")
    {
      "worktrees" => card(worktrees_data(rows, sessions, local["data"]), local["fetched_at"], worktrees_error),
      "agents" => card(agents_data(sessions, local["data"]), local["fetched_at"], @local_error),
      "needs_you" => needs_you_card(sessions, prs, linear, quota, rows),
      "prs" => card(prs, source("prs")["fetched_at"], @prs_error),
      "linear" => card(linear, source("linear")["fetched_at"], @linear_error),
      "quota" => card(quota, source("quota")["fetched_at"], @quota_error),
      "machines" => card(machines, source("machines")["fetched_at"], @machines_error)
    }
  end

  def card(data, fetched_at, error)
    error = "no data yet" if error.nil? && data.nil?
    { "data" => data, "fetched_at" => fetched_at, "error" => error }
  end

  def worktrees_error
    errs = [@local_error, @remote_error].compact
    errs.empty? ? nil : errs.uniq.join("; ")
  end

  # needs_you is a projection of the local, prs, linear, quota and machines
  # sources. Its freshness is the oldest of them, and it carries their errors,
  # or it reads as current while the rows it is built from are stale.
  def needs_you_card(sessions, prs, linear, quota, rows)
    names = %w[local prs linear quota machines]
    # With nothing fetched, an empty list would assert that nothing needs you.
    # Overlay GC stays off in that case too.
    pending_keys = []
    snoozed = 0
    snoozed_keys = []
    if names.any? { |n| !source_data(n).nil? }
      raw = build_needs_you(sessions, prs, linear, quota, rows, source_data("machines"))
      data, pending_keys, snoozed, snoozed_keys = apply_needs_you_overlay(raw, needs_you_availability)
    else
      data = nil
    end
    errs = [@local_error, @prs_error, @quota_error, @machines_error].compact
    errs << @linear_error if @linear_error && @linear_error != NO_LINEAR_KEY
    error = errs.empty? ? nil : errs.uniq.join("; ")
    error = "no data yet" if error.nil? && data.nil?
    {
      "data" => data,
      "fetched_at" => names.filter_map { |n| source(n)["fetched_at"] }.min,
      "error" => error,
      "pending_keys" => pending_keys,
      "snoozed" => snoozed,
      # clear_keys only, so the page can union this list with an optimistic
      # snooze. /needs_you/summary stays counts-only and does not copy it.
      "snoozed_keys" => snoozed_keys
    }
  end

  def needs_you_availability
    NEEDS_YOU_SNAPSHOT.to_h do |source_id, snapshot|
      src = source(snapshot)
      [source_id, {
        "loaded" => !src["data"].nil?,
        "fetched_at" => src["fetched_at"],
        "refresh_started_at" => src["refresh_started_at"]
      }]
    end
  end

  def overlay_entries
    return {} unless @overlay.is_a?(Hash) && @overlay["entries"].is_a?(Hash)

    @overlay["entries"]
  end

  # Opinion 5. A refresh that started before the click does not confirm the
  # hide, even when its result is published afterward. Snapshots store
  # refresh_started_at for that. With no start stamp, fetched_at has to be
  # after the click.
  def pending_confirmed?(entry, avail)
    avail = { "fetched_at" => avail } unless avail.is_a?(Hash)
    current = parse_time(avail["fetched_at"])
    return false if current.nil?

    stored = parse_time(entry["source_fetched_at"])
    return false if stored && current <= stored

    click = parse_time(entry["at"])
    started = parse_time(avail["refresh_started_at"])
    if started
      return false if click && started <= click
    elsif click && current <= click
      return false
    end

    true
  end

  # Packet backstop: a pending hide that never sees a refresh returns after
  # 15 minutes so a stalled source cannot hide the row forever.
  def pending_ttl_expired?(entry, avail, now)
    at = parse_time(entry["at"])
    return false if at.nil?
    return false unless now > (at + PENDING_TTL)

    !pending_confirmed?(entry, avail)
  end

  def until_change_due?(entry, row, now)
    at = parse_time(entry["at"])
    return true if at && now >= (at + UNTIL_CHANGE_BACKSTOP)

    entry["token"].to_s != row["change_token"].to_s
  end

  def source_for_clear_key(key)
    prefix = key.to_s.split(":", 2).first
    NEEDS_YOU_SNAPSHOT.key?(prefix) ? prefix : nil
  end

  # Returns [visible_rows, entries, pending_keys, snoozed_count, snoozed_keys].
  # snoozed_keys are clear_keys only. An entry is dropped for absence only
  # when its own source is loaded. While that source is missing, the entry
  # is kept and no clock rule runs.
  def project_overlay(raw_rows, entries, availability, now = utc_now)
    raw_by_key = {}
    raw_rows.each do |row|
      key = row["clear_key"].to_s
      next if key.empty?

      raw_by_key[key] = row
    end
    pending_keys = []
    snoozed_keys = []
    hidden = {}
    kept = {}
    entries.each do |key, entry|
      next unless key.is_a?(String)
      next unless entry.is_a?(Hash) && %w[pending until until_change].include?(entry["mode"].to_s)

      source = entry["source"].to_s
      source = source_for_clear_key(key).to_s if source.empty?
      avail = availability[source] || { "loaded" => false }
      unless avail["loaded"]
        kept[key] = entry
        next
      end

      row = raw_by_key[key]
      next if row.nil?

      case entry["mode"].to_s
      when "pending"
        if pending_confirmed?(entry, avail) || pending_ttl_expired?(entry, avail, now)
          next
        end

        hidden[key] = true
        pending_keys << key
        kept[key] = entry
      when "until"
        until_at = parse_time(entry["until"])
        next if until_at.nil? || now >= until_at

        hidden[key] = true
        snoozed_keys << key
        kept[key] = entry
      when "until_change"
        next if until_change_due?(entry, row, now)

        hidden[key] = true
        snoozed_keys << key
        kept[key] = entry
      end
    end
    visible = raw_rows.reject { |row| hidden[row["clear_key"].to_s] }
    [visible, kept, pending_keys, snoozed_keys.length, snoozed_keys]
  end

  def apply_needs_you_overlay(raw_rows, availability, now = utc_now)
    before = overlay_entries
    visible, kept, pending_keys, snoozed, snoozed_keys = project_overlay(raw_rows, before, availability, now)
    @overlay = { "version" => 1, "entries" => kept }
    begin
      save_overlay if JSON.generate(before) != JSON.generate(kept)
    rescue StandardError => e
      warn "needs-you overlay write failed: #{e.message}"
      @overlay = { "version" => 1, "entries" => before }
    end
    [visible, pending_keys, snoozed, snoozed_keys]
  end

  def age_seconds(since, now)
    t = parse_time(since)
    return nil if t.nil?

    age = (now - t).to_i
    age.negative? ? 0 : age
  end

  # Same edges as the page: exactly 1d, 3d, and 7d fall in the older bucket.
  def age_bucket(since, now)
    t = parse_time(since)
    return nil if t.nil?

    age = now - t
    age = 0 if age.negative?
    if age < 86_400
      "lt_1d"
    elsif age < 3 * 86_400
      "d1_3"
    elsif age < 7 * 86_400
      "d3_7"
    else
      "gt_7d"
    end
  end

  # Integers and null only. Does not copy a row, a string field, or a clear_key.
  def summary_from(visible_rows, pending_count, snoozed_count, now = utc_now)
    tiers = { "direct" => 0, "blocked" => 0, "team" => 0, "info" => 0 }
    sources = SUMMARY_SOURCES.to_h { |name| [name, 0] }
    ages = { "lt_1d" => 0, "d1_3" => 0, "d3_7" => 0, "gt_7d" => 0 }
    oldest = nil
    visible_rows.each do |row|
      tier_key = SUMMARY_TIER_KEY[row["tier"].to_s]
      if tier_key
        tiers[tier_key] += 1
      else
        warn "needs-you summary: unexpected tier #{row["tier"].inspect}"
      end
      source_key = row["source"].to_s
      if sources.key?(source_key)
        sources[source_key] += 1
      else
        warn "needs-you summary: unexpected source #{source_key.inspect}"
      end
      bucket = age_bucket(row["since"], now)
      ages[bucket] += 1 if bucket && ages.key?(bucket)
      age_s = age_seconds(row["since"], now)
      next if age_s.nil?

      oldest = age_s if oldest.nil? || age_s > oldest
    end
    {
      "tiers" => tiers,
      "sources" => sources,
      "ages" => ages,
      "oldest_age_s" => oldest,
      "pending" => pending_count.to_i,
      "snoozed" => snoozed_count.to_i
    }
  end

  def raw_needs_you
    local = source("local")
    wt_rows = compose_worktree_rows(local["data"], source_data("pings"))
    sessions = local_sessions(local["data"])
    linear = compose_linear(source_data("linear"), wt_rows)
    build_needs_you(sessions, source_data("prs"), linear, source_data("quota"), wt_rows, source_data("machines"))
  end

  def request_body(req)
    raw = req.body
    text = raw.respond_to?(:read) ? raw.read.to_s : raw.to_s
    return nil if text.bytesize > OVERLAY_BODY_MAX

    text
  end

  def json_error(res, status, message)
    res.status = status
    res["Content-Type"] = "application/json"
    res.body = JSON.generate({ "error" => message })
  end

  def record_overlay(clear_key, mode, until_value, now = utc_now)
    previous = overlay_entries
    return [:bad, "missing clear_key"] unless clear_key.is_a?(String) && !clear_key.empty? && clear_key.bytesize <= 512
    return [:bad, "bad mode"] unless %w[pending until until_change].include?(mode)

    raw = raw_needs_you
    row = raw.find { |item| item["clear_key"] == clear_key }
    return [:missing, "unknown clear_key"] if row.nil?

    until_iso = nil
    if mode == "until"
      until_at = parse_time(until_value)
      return [:bad, "bad until"] if until_at.nil?
      return [:bad, "until in the past"] if until_at <= now
      return [:bad, "until too far"] if until_at > (now + SNOOZE_UNTIL_MAX)

      until_iso = iso(until_at)
    end
    avail = needs_you_availability[row["source"].to_s] || {}
    entry = {
      "mode" => mode,
      "at" => iso(now),
      "until" => until_iso,
      "token" => row["change_token"].to_s,
      "source_fetched_at" => avail["fetched_at"],
      "source" => row["source"].to_s
    }
    @overlay = { "version" => 1, "entries" => previous.merge(clear_key => entry) }
    save_overlay
    [:ok, nil]
  rescue StandardError => e
    @overlay = { "version" => 1, "entries" => previous }
    warn "needs-you overlay write failed: #{e.message}"
    [:error, "write failed"]
  end

  def local_rows(local)
    local.is_a?(Hash) && local["rows"].is_a?(Array) ? local["rows"] : []
  end

  def local_sessions(local)
    local.is_a?(Hash) && local["sessions"].is_a?(Array) ? local["sessions"] : []
  end

  # A worktree row is a local fact plus three joins: its PR from the `gh pr
  # list` map, its agent sessions, and its smoke pings. Each row is a fresh
  # hash, so the source rows stay untouched and the payload needs no clone.
  def compose_worktree_rows(local, pings)
    rows = local_rows(local)
    sessions = local_sessions(local)
    pings = {} unless pings.is_a?(Hash)
    by_path = sessions.group_by { |s| longest_worktree(s["cwd"], rows)&.[]("path") }
    rows.map do |row|
      pr = pr_for(row["branch"], row["name"], row["detached"], @pr_maps[row["repo"]] || empty_pr_map)
      prunable, reason = prune?(
        row["is_main"], row["detached"], row["path"],
        row["merged_into_develop"], pr, parse_time(row["last_session_at"])
      )
      root = REPOS.find { |r| r["name"] == row["repo"] }&.[]("root")
      port = row["app_port"]
      row.merge(
        "pr" => pr,
        "prunable" => prunable,
        "prune_reason" => reason,
        "prune_command" => prunable && root ? "git -C #{root} worktree remove #{row["path"]}" : nil,
        "agents" => by_path[row["path"]] || [],
        "pings" => port.nil? ? [] : (pings[port.to_s] || [])
      )
    end
  end

  def worktrees_data(rows, sessions, local)
    return nil if local.nil?

    {
      "repos" => REPOS.map { |r| { "name" => r["name"], "root" => r["root"], "db_port" => r["db_port"] } },
      "rows" => rows,
      "counts" => {
        "worktrees" => rows.size,
        "sessions" => sessions.size,
        "prunable" => rows.count { |r| r["prunable"] }
      }
    }
  end

  def agents_data(sessions, local)
    return nil if local.nil?

    {
      "sessions" => sessions,
      "counts" => {
        "claude" => sessions.count { |s| s["tool"] == "claude" },
        "grok" => sessions.count { |s| s["tool"] == "grok" },
        "codex_today" => sessions.count { |s| s["tool"] == "codex" }
      }
    }
  end

  # A Linear issue's worktrees, its agent and therefore its group all depend on
  # the current worktree rows, so they are read here rather than stored.
  def compose_linear(data, wt_rows)
    return nil unless data.is_a?(Hash)

    mine = (data["mine"] || []).map do |row|
      wts = matching_worktree_names(row["id"], wt_rows)
      group = linear_group(row["state"], row["state_type"], row["labels"] || [], wts)
      since = group == "waiting" ? (row["last_comment_at"] || row["updated_at"]) : row["updated_at"]
      row.merge(
        "worktrees" => wts,
        "agent" => first_active_agent(row["id"], wt_rows),
        "group" => group,
        "since" => since
      )
    end
    mentions = data["mentions"].is_a?(Array) ? data["mentions"] : []
    {
      "mine" => mine,
      "mentions" => mentions,
      "counts" => {
        "mine" => mine.size,
        "waiting" => mine.count { |r| r["group"] == "waiting" },
        "in_progress" => mine.count { |r| r["group"] == "in_progress" },
        "next_up" => mine.count { |r| r["group"] == "next_up" },
        "mentions" => mentions.size
      }
    }
  end

  def handle_health(req, res)
    return unless allow_origin!(req, res)

    res.status = 200
    res["Content-Type"] = "application/json"
    res.body = JSON.generate({ "ok" => true })
  end

  def handle_cards(req, res)
    return unless allow_origin!(req, res)

    payload = @mutex.synchronize do
      { "server_time" => iso(utc_now), "profile" => PROFILE_VIEW, "cards" => compose_cards }
    end
    res.status = 200
    res["Content-Type"] = "application/json"
    res.body = JSON.generate(payload)
  end

  def handle_needs_you_summary(req, res)
    return unless allow_origin!(req, res)
    unless req.request_method == "GET"
      json_error(res, 405, "method not allowed")
      return
    end

    body = @mutex.synchronize do
      names = %w[local prs linear quota machines]
      if names.any? { |n| !source_data(n).nil? }
        visible, pending_keys, snoozed = apply_needs_you_overlay(raw_needs_you, needs_you_availability)
        summary_from(visible, pending_keys.length, snoozed)
      else
        summary_from([], 0, 0)
      end
    end
    res.status = 200
    res["Content-Type"] = "application/json"
    res.body = JSON.generate(body)
  end

  def handle_needs_you_overlay(req, res)
    return unless allow_origin!(req, res)
    unless req.request_method == "POST"
      json_error(res, 405, "method not allowed")
      return
    end

    text = request_body(req)
    if text.nil?
      json_error(res, 400, "body too large")
      return
    end
    begin
      parsed = JSON.parse(text)
    rescue JSON::ParserError
      json_error(res, 400, "bad json")
      return
    end
    unless parsed.is_a?(Hash)
      json_error(res, 400, "bad json")
      return
    end

    status = @mutex.synchronize do
      record_overlay(parsed["clear_key"], parsed["mode"].to_s, parsed["until"])
    end
    case status[0]
    when :ok
      res.status = 204
      res.body = ""
    when :missing
      json_error(res, 404, status[1])
    when :bad
      json_error(res, 400, status[1])
    else
      json_error(res, 500, status[1])
    end
  end

  def allow_origin!(req, res)
    return false unless allow_host!(req, res)

    origin = req["Origin"]
    if origin.nil? || origin.empty?
      return true
    end

    if origin_allowed?(origin)
      res["Access-Control-Allow-Origin"] = origin
      return true
    end

    res.status = 403
    res["Content-Type"] = "application/json"
    res.body = JSON.generate({ "error" => "forbidden origin" })
    false
  end

  # A request with no Origin is allowed on purpose, so curl keeps working. That
  # also lets through a same-origin GET from a page an attacker resolved to
  # 127.0.0.1 by DNS rebinding, whose Host header carries the attacker's name.
  # Pin the Host to the address this process actually binds.
  def allow_host!(req, res)
    host = req["Host"].to_s
    return true if host.empty? || host_allowed?(host)

    res.status = 403
    res["Content-Type"] = "application/json"
    res.body = JSON.generate({ "error" => "forbidden host" })
    false
  end

  def host_allowed?(host)
    m = host.downcase.match(/\A(\[[0-9a-f:.]+\]|[^:\[\]]+)(?::(\d+))?\z/)
    return false if m.nil?
    return false if m[2] && m[2].to_i != BIND_PORT

    ALLOWED_HOSTS.include?(m[1].delete_prefix("[").delete_suffix("]"))
  end

  def origin_allowed?(origin)
    id = ENV["OPS_TAB_EXTENSION_ID"].to_s.strip
    return true if !id.empty? && origin == "chrome-extension://#{id}"
    return false unless ENV["OPS_TAB_DEV"] == "1"
    return true if origin == "null"
    return true if origin.match?(%r{\Ahttp://127\.0\.0\.1(?::\d+)?\z})

    false
  end
end

OpsTabServer.new.run if $PROGRAM_NAME == __FILE__
