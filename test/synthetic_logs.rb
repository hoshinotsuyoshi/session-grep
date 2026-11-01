# frozen_string_literal: true

# Writes made-up Claude Code and codex session logs for comparing a compiled binary with the
# Ruby script (test/compare_binary.rb) and for timing them (test/perf.rb).
# The same seed and scale always give the same files, with fixed mtimes.
#
#   ruby test/synthetic_logs.rb DIR [SCALE]   # DIR/projects (Claude) and DIR/codex
#
# Search words with known frequencies:
#   zephyr  in about a third of the sessions
#   quokka  in a few sessions
#   猫柳    in about a fifth of the sessions (non-ASCII)
#   absentterm  nowhere

require "json"
require "fileutils"
require "time"

module SyntheticLogs
  BASE = Time.utc(2026, 1, 1)
  EN = %w[
    the build test failed because config branch merge review deploy cache index session agent tool
    output error retry timeout fixture parser token release workflow runner commit diff patch
    request response handler module function method class string array hash value field option
  ].freeze
  JA = %w[
    確認 修正 テスト 失敗 原因 調査 設定 ブランチ 差分 レビュー 実行 結果 対応 追加 削除 変更
    ログ 検索 速度 出力
  ].freeze
  HC = ["<hc from=\"t1 lead\">", "<teammate-message from=\"x\">"].freeze

  module_function

  # scale multiplies the number of sessions; each session's size stays the same
  def generate(dir, scale: 1, seed: 1)
    rng = Random.new(seed)
    claude = File.join(dir, "projects")
    codex = File.join(dir, "codex")
    (4 * scale).times { |p| claude_project(rng, claude, p) }
    codex_sessions(rng, codex, 20 * scale)
    { claude_dir: claude, codex_dir: codex }
  end

  def uuid(rng)
    h = rng.bytes(16).unpack1("H*")
    "#{h[0, 8]}-#{h[8, 4]}-#{h[12, 4]}-#{h[16, 4]}-#{h[20, 12]}"
  end

  def sentence(rng, terms, min = 4, max = 25)
    words = Array.new(rng.rand(min..max)) { rng.rand < 0.5 ? EN.sample(random: rng) : JA.sample(random: rng) }
    terms.each { |t| words.insert(rng.rand(words.size + 1), t) if rng.rand < 0.3 }
    words.join(" ")
  end

  def terms_for(rng)
    t = []
    t << "zephyr" if rng.rand < 0.33
    t << "quokka" if rng.rand < 0.04
    t << "猫柳" if rng.rand < 0.2
    t
  end

  def ts(time)
    time.utc.strftime("%Y-%m-%dT%H:%M:%S.%LZ")
  end

  def write(path, records, mtime)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, records.map { |r| JSON.generate(r) }.join("\n") + "\n")
    File.utime(mtime, mtime, path)
  end

  # A large tool output line, the kind that makes JSON parsing slow
  def big_text(rng, terms)
    size = rng.rand(20_000..200_000)
    text = +""
    text << sentence(rng, terms, 20, 60) << "\n" while text.bytesize < size
    text
  end

  def claude_project(rng, root, index)
    cwd = "/home/u/src/github.com/org-#{index % 3}/proj-#{format('%02d', index)}"
    dir = File.join(root, cwd.gsub(/[^A-Za-z0-9]/, "-"))
    sessions = []
    5.times do
      sid = uuid(rng)
      start = BASE + rng.rand(0..(60 * 86_400))
      terms = terms_for(rng)
      records, last = claude_records(rng, cwd, sid, start, terms)
      write(File.join(dir, "#{sid}.jsonl"), records, last)
      sessions << [sid, records, start]
      next unless rng.rand < 0.3

      agent = "a#{rng.bytes(4).unpack1('H*')}"
      sub, sub_last = claude_records(rng, cwd, sid, start + 60, terms_for(rng), sidechain: agent)
      write(File.join(dir, sid, "subagents", "agent-#{agent}.jsonl"), sub, sub_last)
    end
    # A session forked from another: copies of the parent's lines carry forkedFrom
    sid, records, start = sessions.first
    fork_id = uuid(rng)
    copied = records.first(10).map { |r| r.merge(sessionId: fork_id, forkedFrom: { sessionId: sid, messageUuid: "u" }) }
    own, last = claude_records(rng, cwd, fork_id, start + 7200, terms_for(rng))
    write(File.join(dir, "#{fork_id}.jsonl"), copied + own, last)
  end

  def claude_records(rng, cwd, sid, start, terms, sidechain: nil)
    t = start
    base = { cwd: cwd, gitBranch: "main", sessionId: sid }
    base = base.merge(isSidechain: true, agentId: sidechain) if sidechain
    records = [{ type: "permission-mode", permissionMode: "auto", sessionId: sid },
               base.merge(type: "attachment", timestamp: ts(t), attachment: { content: "skills: zephyr-skill" })]
    rng.rand(30..150).times do
      t += rng.rand < 0.1 ? 0 : rng.rand(1..120) # some lines share a timestamp
      stamp = rng.rand < 0.03 ? {} : { timestamp: ts(t) }
      records << base.merge(stamp).merge(claude_line(rng, terms))
    end
    records << { type: "ai-title", aiTitle: sentence(rng, terms, 2, 5), sessionId: sid } unless sidechain
    [records, t]
  end

  def claude_line(rng, terms)
    user = ->(content, extra = {}) { { type: "user", message: { role: "user", content: content } }.merge(extra) }
    assistant = ->(content) { { type: "assistant", message: { role: "assistant", content: content } } }
    case rng.rand(100)
    when 0...15 then user.call(sentence(rng, terms))
    when 15...18 then user.call("#{HC.sample(random: rng)}#{sentence(rng, terms)}")
    when 18...21
      user.call([{ type: "text", text: "<system-reminder>#{sentence(rng, terms)}</system-reminder>" },
                 { type: "text", text: sentence(rng, terms) }])
    when 21...23 then user.call("<task-notification>#{sentence(rng, terms)}")
    when 23...25 then user.call([{ type: "text", text: sentence(rng, terms) }], isMeta: true)
    when 25...45 then assistant.call([{ type: "text", text: sentence(rng, terms, 10, 60) }])
    when 45...65 then assistant.call([{ type: "tool_use", name: "Bash", input: { command: sentence(rng, terms, 3, 10) } }])
    when 65...72 then assistant.call([{ type: "thinking", thinking: sentence(rng, terms, 10, 40) }])
    when 72...75
      user.call([{ type: "tool_result", content: big_text(rng, terms) }])
    else user.call([{ type: "tool_result", content: sentence(rng, terms, 5, 80) }])
    end
  end

  def codex_sessions(rng, root, count)
    index = []
    count.times do |i|
      id = uuid(rng)
      start = BASE + rng.rand(0..(60 * 86_400))
      terms = terms_for(rng)
      cwd = "/home/u/src/github.com/org-#{i % 3}/proj-#{format('%02d', i % 8)}"
      day = start.utc.strftime("%Y/%m/%d")
      name = "rollout-#{start.utc.strftime('%Y-%m-%dT%H-%M-%S')}-#{id}.jsonl"
      records, last = codex_records(rng, id, cwd, start, terms)
      write(File.join(root, "sessions", day, name), records, last)
      index << { id: id, thread_name: sentence(rng, terms, 2, 5) }
    end
    FileUtils.mkdir_p(root)
    File.write(File.join(root, "session_index.jsonl"), index.map { |r| JSON.generate(r) }.join("\n") + "\n")
  end

  def codex_records(rng, id, cwd, start, terms)
    t = start
    source = rng.rand < 0.1 ? { subagent: "review" } : "cli"
    records = [{ type: "session_meta", timestamp: ts(t),
                 payload: { id: id, cwd: cwd, timestamp: ts(t), git: { branch: "feat/x" }, source: source } },
               codex_message(ts(t), "user", "# AGENTS.md instructions for #{cwd}\n#{sentence(rng, terms)}")]
    rng.rand(30..150).times do
      t += rng.rand < 0.1 ? 0 : rng.rand(1..120)
      records << codex_line(rng, ts(t), terms)
    end
    [records, t]
  end

  def codex_message(stamp, role, text)
    { type: "response_item", timestamp: stamp,
      payload: { type: "message", role: role, content: [{ type: "input_text", text: text }] } }
  end

  def codex_line(rng, stamp, terms)
    item = ->(payload) { { type: "response_item", timestamp: stamp, payload: payload } }
    case rng.rand(100)
    when 0...15 then codex_message(stamp, "user", sentence(rng, terms))
    when 15...18 then codex_message(stamp, "user", "#{HC.first}#{sentence(rng, terms)}")
    when 18...35 then codex_message(stamp, "assistant", sentence(rng, terms, 10, 60))
    when 35...40 then codex_message(stamp, "developer", sentence(rng, terms))
    when 40...50 then item.call(type: "reasoning", summary: [{ type: "summary_text", text: sentence(rng, terms) }])
    when 50...65 then item.call(type: "function_call", name: "shell", arguments: JSON.generate(cmd: sentence(rng, terms, 3, 10)))
    when 65...68 then item.call(type: "function_call_output", call_id: "c", output: big_text(rng, terms))
    when 68...85 then item.call(type: "function_call_output", call_id: "c", output: sentence(rng, terms, 5, 80))
    else { type: "event_msg", timestamp: stamp, payload: { type: "user_message", message: sentence(rng, terms) } }
    end
  end
end

if $PROGRAM_NAME == __FILE__
  dir = ARGV.fetch(0) { abort "usage: ruby test/synthetic_logs.rb DIR [SCALE]" }
  scale = Integer(ARGV.fetch(1, "1"))
  SyntheticLogs.generate(dir, scale: scale)
end
