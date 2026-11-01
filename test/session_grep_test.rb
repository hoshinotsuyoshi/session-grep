# frozen_string_literal: true

# Run: ruby test/session_grep_test.rb
#      SG_BIN=/path/to/session-grep ruby test/session_grep_test.rb  (against a compiled binary)
# Run it on both Ruby 3.4.4 and 4.0.7 (RBENV_VERSION=3.4.4 ruby ...)
#
# The fixtures are partly Japanese on purpose: real logs are in the user's language.

require "minitest/autorun"
require "json"
require "open3"
require "tmpdir"
require "fileutils"

SCRIPT = File.expand_path("../bin/session-grep", __dir__)
CLI = ENV["SG_BIN"] ? [File.expand_path(ENV["SG_BIN"])] : [RbConfig.ruby, SCRIPT]
load SCRIPT

# Lets a test make rg list files in reverse order, since its real order is not fixed
module ReverseRgOrder
  attr_accessor :reverse_rg

  def rg_filter(*)
    reverse_rg ? super.sort.reverse : super
  end
end
SessionGrep.singleton_class.prepend(ReverseRgOrder)

class SessionGrepTest < Minitest::Test
  CWD_A = "/Users/x/src/github.com/example-org/app-01"
  CWD_B = "/Users/x/src/github.com/other/repo"
  SID = "11111111-1111-1111-1111-111111111111"
  SID2 = "22222222-2222-2222-2222-222222222222"
  SID3 = "33333333-3333-3333-3333-333333333333"
  SID4 = "44444444-4444-4444-4444-444444444444"
  CODEX_ID = "019a0000-aaaa-7bbb-8ccc-dddddddddddd"

  def setup
    @dir = Dir.mktmpdir
    @claude = File.join(@dir, "projects")
    @codex = File.join(@dir, "codex")
    build_claude
    build_codex
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def write_jsonl(path, records)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, records.map { |r| JSON.generate(r) }.join("\n") + "\n")
  end

  def user(cwd, sid, content, ts, extra = {})
    { parentUuid: nil, type: "user", cwd: cwd, gitBranch: "main", sessionId: sid, timestamp: ts,
      message: { role: "user", content: content } }.merge(extra)
  end

  def assistant(cwd, sid, content, ts)
    { type: "assistant", cwd: cwd, gitBranch: "main", sessionId: sid, timestamp: ts,
      message: { role: "assistant", content: content } }
  end

  def build_claude
    proj_a = File.join(@claude, CWD_A.gsub(/[^A-Za-z0-9]/, "-"))
    write_jsonl(File.join(proj_a, "#{SID}.jsonl"), [
      { type: "permission-mode", permissionMode: "auto", sessionId: SID },
      { type: "attachment", cwd: CWD_A, sessionId: SID, timestamp: "2026-10-01T00:00:00Z",
        attachment: { content: "skills: banana-skill" } },
      user(CWD_A, SID, "最初の質問です", "2026-10-01T00:00:01Z"),
      user(CWD_A, SID, "banana の件どうなった?", "2026-10-01T00:00:02Z"),
      assistant(CWD_A, SID, [{ type: "text", text: "banana は対応済みです" }], "2026-10-01T00:00:03Z"),
      assistant(CWD_A, SID, [{ type: "tool_use", name: "Bash", input: { command: "rg banana" } }],
                "2026-10-01T00:00:04Z"),
      user(CWD_A, SID, [{ type: "tool_result", content: "banana.txt" }], "2026-10-01T00:00:05Z"),
      user(CWD_A, SID, [{ type: "text", text: "Base directory for this skill: banana" }],
           "2026-10-01T00:00:06Z", isMeta: true),
      user(CWD_A, SID, "<hc from=\"t1 lead\">cherry を調べて", "2026-10-01T00:00:07Z"),
      assistant(CWD_A, SID, [{ type: "text", text: "elder の結果をまとめました" }], "2026-10-01T00:02:00Z"),
      { type: "ai-title", aiTitle: "banana 対応", sessionId: SID }
    ])
    # subagent: the parent is SID
    write_jsonl(File.join(proj_a, SID, "subagents", "agent-afable-1.jsonl"), [
      user(CWD_A, SID, "durian をレビューして", "2026-10-01T00:01:00Z", isSidechain: true, agentId: "afable-1"),
      assistant(CWD_A, SID, [{ type: "text", text: "elder を確認" }], "2026-10-01T00:01:30Z")
    ])
    # Another session that matches only in meta (noise from the skill list)
    proj_b = File.join(@claude, CWD_B.gsub(/[^A-Za-z0-9]/, "-"))
    write_jsonl(File.join(proj_b, "#{SID2}.jsonl"), [
      { type: "attachment", cwd: CWD_B, sessionId: SID2, timestamp: "2026-10-02T00:00:00Z",
        attachment: { content: "skills: banana-skill" } },
      user(CWD_B, SID2, "apple の話", "2026-10-02T00:00:01Z")
    ])
    # A session spanning two dates (JST 10-01 23:00 and 10-02 01:00)
    write_jsonl(File.join(proj_a, "#{SID3}.jsonl"), [
      user(CWD_A, SID3, "grape を調べて", "2026-10-01T14:00:00Z"),
      assistant(CWD_A, SID3, [{ type: "text", text: "grape は 2 件" }], "2026-10-01T16:00:00Z")
    ])
    # A session forked from SID: the copied lines have forkedFrom
    fork = { forkedFrom: { sessionId: SID, messageUuid: "u1" } }
    write_jsonl(File.join(proj_a, "#{SID4}.jsonl"), [
      user(CWD_A, SID4, "最初の質問です", "2026-10-01T00:00:01Z", fork),
      user(CWD_A, SID4, "banana の件どうなった?", "2026-10-01T00:00:02Z", fork),
      user(CWD_A, SID4, "fig を追加で", "2026-10-05T00:00:00Z")
    ])
  end

  def build_codex
    path = File.join(@codex, "sessions", "2026", "10", "03", "rollout-2026-10-03T10-00-00-#{CODEX_ID}.jsonl")
    msg = ->(role, text) { { type: "response_item", timestamp: "2026-10-03T01:00:00Z",
                             payload: { type: "message", role: role, content: [{ type: "input_text", text: text }] } } }
    write_jsonl(path, [
      { type: "session_meta", timestamp: "2026-10-03T01:00:00Z",
        payload: { id: CODEX_ID, cwd: CWD_A, timestamp: "2026-10-03T01:00:00Z",
                   git: { branch: "feat/x" }, source: "cli" } },
      msg.call("developer", "banana 開発者向け"),
      msg.call("user", "# AGENTS.md instructions for /x\nbanana"),
      msg.call("user", "PR の banana をレビューして"),
      { type: "event_msg", timestamp: "2026-10-03T01:00:01Z",
        payload: { type: "user_message", message: "PR の banana をレビューして" } },
      msg.call("assistant", "banana に問題はありません"),
      { type: "response_item", timestamp: "2026-10-03T01:00:02Z",
        payload: { type: "function_call_output", call_id: "c1", output: "banana.rb" } }
    ])
    File.write(File.join(@codex, "session_index.jsonl"),
               JSON.generate({ id: CODEX_ID, thread_name: "banana レビュー" }) + "\n")
  end

  # SG_BIN=/path/to/binary runs the CLI tests against a compiled binary instead of bin/session-grep.
  # Tests that call SessionGrep methods directly still exercise the Ruby script
  def run_cli(*args, env: {})
    env = { "SESSION_GREP_CLAUDE_DIR" => @claude, "SESSION_GREP_CODEX_DIR" => @codex,
            "TZ" => "Asia/Tokyo", "CLAUDE_CODE_SESSION_ID" => "" }.merge(env)
    Open3.capture3(env, *CLI, *args)
  end

  def json_cli(*args, env: {})
    out, err, status = run_cli(*args, "--json", env: env)
    [out.lines.map { |l| JSON.parse(l) }, err, status]
  end

  def test_claude_session_summary_and_kinds
    list, _, status = json_cli("banana", "--tool", "claude")
    assert_equal 0, status.exitstatus
    assert_equal [SID], list.map { |s| s["session_id"] }
    s = list.first
    assert_equal CWD_A, s["cwd"]
    assert_equal "main", s["branch"]
    assert_equal "banana 対応", s["title"]
    assert_equal "最初の質問です", s["first_prompt"]
    assert_equal %w[human agent], s["hits"].map { |h| h["kind"] }
    assert_equal 2, s["hit_counts"]["tool"]
    assert_equal 3, s["hit_counts"]["meta"] # attachment, isMeta, ai-title
    assert_equal "cd #{CWD_A} && claude --resume #{SID}", s["resume"]
  end

  def test_meta_only_session_is_hidden_by_default_and_shown_with_all
    list, = json_cli("banana", "--tool", "claude")
    refute_includes list.map { |s| s["session_id"] }, SID2
    list, = json_cli("banana", "--tool", "claude", "--all")
    assert_includes list.map { |s| s["session_id"] }, SID2
  end

  def test_hc_message_kind
    list, = json_cli("cherry")
    assert_equal ["hc"], list.first["hits"].map { |h| h["kind"] }
  end

  # In a session moved to the desktop app, human input is an array with a system-reminder text block in front
  def test_system_reminder_block_before_human_text_is_meta
    sid = "55555555-5555-5555-5555-555555555555"
    proj = File.join(@claude, CWD_B.gsub(/[^A-Za-z0-9]/, "-"))
    reminder = "<system-reminder>\nThis conversation is now continuing in the Claude desktop app (Code tab).\n</system-reminder>"
    write_jsonl(File.join(proj, "#{sid}.jsonl"), [
      user(CWD_B, sid, [{ type: "text", text: reminder }, { type: "text", text: "kiwi を調べたい" }],
           "2026-10-06T00:00:01Z"),
      user(CWD_B, sid, [{ type: "text", text: reminder }], "2026-10-06T00:00:02Z")
    ])
    list, = json_cli("kiwi")
    s = list.find { |x| x["session_id"] == sid }
    assert_equal "kiwi を調べたい", s["first_prompt"]
    assert_equal ["human"], s["hits"].map { |h| h["kind"] }
    refute_includes s["hits"].first["text"], "desktop app"

    list, = json_cli("desktop app")
    refute_includes list.map { |x| x["session_id"] }, sid
    list, = json_cli("desktop app", "--all")
    s = list.find { |x| x["session_id"] == sid }
    assert_equal 2, s["hit_counts"]["meta"]
  end

  # Agent notifications (<hc>...) and Agent Teams teammate-messages are not human input
  def test_hc_notification_and_teammate_message_are_hc
    sid = "66666666-6666-6666-6666-666666666666"
    proj = File.join(@claude, CWD_B.gsub(/[^A-Za-z0-9]/, "-"))
    write_jsonl(File.join(proj, "#{sid}.jsonl"), [
      user(CWD_B, sid, "lemon を頼みたい", "2026-10-07T00:00:01Z"),
      user(CWD_B, sid, "<hc>t1h lemon exited (signal 9). Read: hc read t1h</hc>", "2026-10-07T00:00:02Z"),
      user(CWD_B, sid, "<teammate-message teammate_id=\"team-lead\">\nlemon をレビューして\n</teammate-message>",
           "2026-10-07T00:00:03Z")
    ])
    list, = json_cli("lemon")
    s = list.find { |x| x["session_id"] == sid }
    assert_equal %w[human hc hc], s["hits"].map { |h| h["kind"] }
  end

  def test_subagent_hits_are_grouped_into_parent
    list, = json_cli("durian")
    assert_equal [SID], list.map { |s| s["session_id"] }
    assert_equal "afable-1", list.first["hits"].first["agent_id"]
    assert_equal "banana 対応", list.first["title"]
    list, _, status = json_cli("durian", "--no-subagents")
    assert_empty list
    assert_equal 1, status.exitstatus
  end

  def test_codex_session
    list, = json_cli("banana", "--tool", "codex")
    assert_equal 1, list.size
    s = list.first
    assert_equal CODEX_ID, s["session_id"]
    assert_equal "feat/x", s["branch"]
    assert_equal "banana レビュー", s["title"]
    assert_equal "PR の banana をレビューして", s["first_prompt"]
    # Duplicate event_msg lines are not counted; AGENTS.md and developer are meta
    assert_equal %w[human agent], s["hits"].map { |h| h["kind"] }
    assert_equal 1, s["hit_counts"]["tool"]
    assert_equal 2, s["hit_counts"]["meta"]
    assert_equal "cd #{CWD_A} && codex resume #{CODEX_ID}", s["resume"]
  end

  def test_cwd_filter
    list, = json_cli("apple", "--all", "--repo", "other/repo")
    assert_equal [SID2], list.map { |s| s["session_id"] }
    list, = json_cli("apple", "--all", "--repo", "example-org")
    assert_empty list
  end

  def test_since_filters_by_mtime
    old = Time.now - (10 * 86_400)
    Dir.glob(File.join(@dir, "**", "*.jsonl")).each { |f| File.utime(old, old, f) }
    list, = json_cli("banana", "--since", "3d")
    assert_empty list
    list, = json_cli("banana", "--since", "11d")
    assert_equal 2, list.size
  end

  def test_ignore_case
    list, = json_cli("BANANA", "--tool", "codex")
    assert_empty list
    list, = json_cli("BANANA", "--tool", "codex", "-i")
    assert_equal 1, list.size
  end

  def test_text_output
    out, _, status = run_cli("banana", "--tool", "claude")
    assert_equal 0, status.exitstatus
    assert_match(/title: banana 対応/, out)
    assert_match(/\[human \d\d:\d\d\] banana の件どうなった\?/, out)
    assert_match(/2 in tool/, out)
    assert_match(/resume: cd .* && claude --resume #{SID}/, out)
  end

  def test_show
    out, _, status = run_cli("--show", CODEX_ID[0, 8])
    assert_equal 0, status.exitstatus
    assert_match(/\[human 10-03 10:00\] PR の banana/, out)
    assert_match(/\[agent 10:00\] banana に問題/, out)
    refute_match(/AGENTS\.md/, out)
  end

  def test_usage_error
    _, err, status = run_cli
    assert_equal 2, status.exitstatus
    assert_match(/Usage/, err)
  end

  # A matching line whose date differs from the previous line shows "MM-DD HH:MM"
  def test_hit_time_shows_date_when_day_changes
    out, = run_cli("grape", "--tool", "claude")
    assert_match(/^2026-10-02 01:00  claude /, out)
    assert_match(/\[human 10-01 23:00\] grape を調べて/, out)
    assert_match(/\[agent 10-02 01:00\] grape は 2 件/, out)
  end

  # Matching lines are in time order (even when the subagent file is read later)
  def test_hits_are_sorted_by_time
    list, = json_cli("elder", "--tool", "claude")
    hits = list.first["hits"]
    assert_equal ["2026-10-01T00:01:30Z", "2026-10-01T00:02:00Z"], hits.map { |h| h["ts"] }
    assert_equal "afable-1", hits.first["agent_id"]
  end

  # rg lists matching files in no fixed order; they are read in sorted order, parent before subagents
  def test_candidate_files_are_sorted
    SessionGrep.reverse_rg = true
    files = Dir.glob(File.join(@claude, "**", "*.jsonl"))
    matcher = SessionGrep::Matcher.new(["elder"], false)
    found = SessionGrep.candidate_files(files, matcher, false) { |f| SessionGrep::Claude.session_id(f) }
    assert_equal ["#{SID}.jsonl", "agent-afable-1.jsonl"], found.map { |f| File.basename(f) }
  ensure
    SessionGrep.reverse_rg = false
  end

  # Hits with the same timestamp (or none) keep the order they appear in the log
  def test_hits_with_same_time_keep_log_order
    sid = "55555555-5555-5555-5555-555555555555"
    texts = (1..30).map { |i| format("kiwi %02d", i) }
    records = texts.each_with_index.map do |t, i|
      ts = i.even? ? "2026-10-04T00:00:00Z" : nil
      user(CWD_B, sid, t, ts)
    end
    write_jsonl(File.join(@claude, CWD_B.gsub(/[^A-Za-z0-9]/, "-"), "#{sid}.jsonl"), records)
    list, = json_cli("kiwi", "--tool", "claude")
    hits = list.first["hits"]
    assert_equal texts.select.with_index { |_, i| i.odd? }, hits.reject { |h| h["ts"] }.map { |h| h["text"] }
    assert_equal texts.select.with_index { |_, i| i.even? }, hits.select { |h| h["ts"] }.map { |h| h["text"] }
  end

  # The heading uses the last message's time, plus the log's mtime if that is later
  def test_header_uses_last_message_time
    list, = json_cli("banana", "--tool", "claude")
    assert_equal "2026-10-01T00:02:00Z", list.first["last_message_at"]
    out, = run_cli("banana", "--tool", "claude")
    assert_match(/^2026-10-01 09:02  claude .*\(log \d\d-\d\d \d\d:\d\d\)$/, out)
  end

  def test_last_message_at_reads_backwards_across_chunks
    path = File.join(@dir, "big.jsonl")
    write_jsonl(path, [user(CWD_A, SID, "first", "2026-10-01T00:00:00Z"),
                       user(CWD_A, SID, [{ type: "tool_result", content: "x" * 5000 }], "2026-10-01T00:09:00Z"),
                       { type: "ai-title", aiTitle: "t", sessionId: SID }])
    assert_equal "2026-10-01T00:00:00Z", SessionGrep.last_message_at(path, SessionGrep::Claude, chunk: 100)
  end

  # Lines copied by a fork are not counted, and the fork origin is shown
  def test_forked_session_does_not_duplicate_parent
    list, = json_cli("banana", "--tool", "claude")
    refute_includes list.map { |s| s["session_id"] }, SID4
    list, = json_cli("fig", "--tool", "claude")
    assert_equal [SID4], list.map { |s| s["session_id"] }
    assert_equal SID, list.first["forked_from"]
    out, = run_cli("fig", "--tool", "claude")
    assert_match(/fork of: #{SID}/, out)
  end

  # The $CLAUDE_CODE_SESSION_ID session is excluded. --include-self / --exclude-session
  def test_excludes_own_session
    env = { "CLAUDE_CODE_SESSION_ID" => SID }
    list, = json_cli("banana", env: env)
    assert_equal [CODEX_ID], list.map { |s| s["session_id"] }
    list, = json_cli("banana", "--include-self", env: env)
    assert_equal [SID, CODEX_ID].sort, list.map { |s| s["session_id"] }.sort
    list, = json_cli("banana", "--exclude-session", CODEX_ID[0, 8])
    assert_equal [SID], list.map { |s| s["session_id"] }
  end

  # Multiple words are ANDed (anywhere in the same session)
  def test_multiple_terms_are_and
    list, = json_cli("-e", "banana", "-e", "cherry")
    assert_equal [SID], list.map { |s| s["session_id"] }
    list, = json_cli("banana", "cherry")
    assert_equal [SID], list.map { |s| s["session_id"] }
    kinds = list.first["hits"].map { |h| h["kind"] }
    assert_includes kinds, "hc"
    # banana in SID2 is only in meta (the skill list), so by default the AND is not satisfied
    list, _, status = json_cli("-e", "banana", "-e", "apple")
    assert_empty list
    assert_equal 1, status.exitstatus
    list, = json_cli("-e", "banana", "-e", "apple", "--all")
    assert_equal [SID2], list.map { |s| s["session_id"] }
  end

  # The help says that --repo matches the cwd the session started in
  def test_help_explains_repo_and_order
    out, = run_cli("--help")
    assert_match(/cwd the session started in/, out)
    assert_match(/AND/, out)
    assert_match(/time order/, out)
  end

  # Non-ASCII search words work, alone and ANDed with ASCII words
  def test_non_ascii_terms
    list, = json_cli("対応済み", "--tool", "claude")
    assert_equal [SID], list.map { |s| s["session_id"] }
    assert_equal ["banana は対応済みです"], list.first["hits"].map { |h| h["text"] }
    list, = json_cli("-e", "banana", "-e", "対応済み", "--tool", "claude")
    assert_equal [SID], list.map { |s| s["session_id"] }
    list, = json_cli("レビュー", "--tool", "codex")
    assert_equal [CODEX_ID], list.map { |s| s["session_id"] }
    list, _, status = json_cli("-e", "対応済み", "-e", "apple", "--tool", "claude")
    assert_empty list
    assert_equal 1, status.exitstatus
  end

  def test_parse_time
    now = Time.utc(2026, 11, 1)
    assert_equal now - (3 * 86_400), SessionGrep.parse_time("3d", now: now)
    assert_equal now - (12 * 3600), SessionGrep.parse_time("12h", now: now)
    assert_equal Time.parse("2026-10-01"), SessionGrep.parse_time("2026-10-01")
    assert_raises(OptionParser::InvalidArgument) { SessionGrep.parse_time("someday") }
  end
end
