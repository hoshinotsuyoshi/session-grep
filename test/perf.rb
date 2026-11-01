# frozen_string_literal: true

# Times bin/session-grep and a compiled binary on the same synthetic logs and prints a Markdown table
# (also appended to $GITHUB_STEP_SUMMARY when set). Both run alternately on the same machine, and only
# the ratio is checked: it fails when the binary is more than MAX_RATIO times slower than the script in
# any case. Absolute times vary too much between CI runners to be checked.
#
#   ruby test/perf.rb /path/to/session-grep [SCALE] [RUNS] [MAX_RATIO]

require "tmpdir"
require_relative "synthetic_logs"

binary = File.expand_path(ARGV.fetch(0) { abort "usage: ruby test/perf.rb BINARY [SCALE] [RUNS] [MAX_RATIO]" })
scale = Integer(ARGV.fetch(1, "10"))
runs = Integer(ARGV.fetch(2, "5"))
max_ratio = Float(ARGV.fetch(3, "1.5"))
script = File.expand_path("../bin/session-grep", __dir__)

def elapsed(env, cmd)
  start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  system(env, *cmd, out: File::NULL, err: File::NULL)
  Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
end

Dir.mktmpdir do |dir|
  logs = SyntheticLogs.generate(dir, scale: scale)
  size = Dir.glob(File.join(dir, "**", "*.jsonl")).sum { |f| File.size(f) }
  env = { "SESSION_GREP_CLAUDE_DIR" => logs[:claude_dir], "SESSION_GREP_CODEX_DIR" => logs[:codex_dir],
          "TZ" => "Asia/Tokyo", "CLAUDE_CODE_SESSION_ID" => "" }
  claude_id = File.basename(Dir.glob(File.join(logs[:claude_dir], "*", "*.jsonl")).min, ".jsonl")
  cases = [%w[--help], %w[absentterm], %w[quokka], %w[zephyr], %w[--all --json zephyr], ["--show", claude_id, "--full"]]

  rows = cases.map do |args|
    cmds = { ruby: [RbConfig.ruby, script, *args], binary: [binary, *args] }
    cmds.each_value { |c| elapsed(env, c) } # warm the page cache
    times = { ruby: [], binary: [] }
    runs.times do |i|
      (i.even? ? %i[ruby binary] : %i[binary ruby]).each { |k| times[k] << elapsed(env, cmds[k]) }
    end
    ruby, bin = times.values.map { |t| t.sort[t.size / 2] }
    [args, ruby, bin, bin / ruby]
  end

  label = ->(args) { args.map { |a| a == claude_id ? "ID" : a }.join(" ") }
  table = ["| args | ruby (s) | binary (s) | binary / ruby |", "|---|---|---|---|"]
  rows.each { |args, r, b, ratio| table << format("| `%s` | %.3f | %.3f | %.2f |", label.call(args), r, b, ratio) }
  report = ["### session-grep: Ruby script vs binary",
            "", "#{(size / 1_000_000.0).round} MB of synthetic logs (scale #{scale}), median of #{runs} runs", "", *table]
  slow = rows.select { |_, _, _, ratio| ratio > max_ratio }
  report += ["", "The binary is more than #{max_ratio}x slower than the script: #{slow.map { |a, *| label.call(a) }.join(', ')}"] if slow.any?

  puts report
  File.write(ENV["GITHUB_STEP_SUMMARY"], "#{report.join("\n")}\n", mode: "a") if ENV["GITHUB_STEP_SUMMARY"]
  exit(slow.empty? ? 0 : 1)
end
