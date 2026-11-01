# frozen_string_literal: true

# Runs bin/session-grep and a compiled binary on the same synthetic logs with the same arguments,
# and fails unless stdout, stderr and the exit status are identical.
#
#   ruby test/compare_binary.rb /path/to/session-grep [SCALE]

require "open3"
require "tmpdir"
require_relative "synthetic_logs"

binary = File.expand_path(ARGV.fetch(0) { abort "usage: ruby test/compare_binary.rb BINARY [SCALE]" })
scale = Integer(ARGV.fetch(1, "2"))
script = File.expand_path("../bin/session-grep", __dir__)

Dir.mktmpdir do |dir|
  logs = SyntheticLogs.generate(dir, scale: scale)
  env = { "SESSION_GREP_CLAUDE_DIR" => logs[:claude_dir], "SESSION_GREP_CODEX_DIR" => logs[:codex_dir],
          "TZ" => "Asia/Tokyo", "CLAUDE_CODE_SESSION_ID" => "" }
  claude_id = File.basename(Dir.glob(File.join(logs[:claude_dir], "*", "*.jsonl")).min, ".jsonl")
  codex_id = Dir.glob(File.join(logs[:codex_dir], "sessions", "**", "*.jsonl")).min[/([0-9a-f-]{36})\.jsonl\z/, 1]

  cases = [
    %w[zephyr],
    %w[-i ZEPHYR],
    %w[zephyr 猫柳],
    %w[-e zephyr -e quokka],
    %w[--all --json zephyr],
    %w[--all -i 猫柳],
    %w[--json quokka],
    %w[--tool codex zephyr],
    %w[--tool claude --no-subagents quokka],
    %w[--cwd proj-03 zephyr],
    %w[--since 2026-01-20 --until 2026-02-10 zephyr],
    %w[--limit 3 --hits 5 zephyr],
    ["--exclude-session", claude_id[0, 8], "zephyr"],
    ["--show", claude_id],
    ["--show", claude_id, "--json", "--full"],
    ["--show", codex_id[0, 13], "--all"],
    %w[absentterm],
    %w[--since bogus zephyr],
    %w[--hits x zephyr],
    %w[--help],
  ]

  failures = cases.count do |args|
    ruby = Open3.capture3(env, RbConfig.ruby, script, *args)
    bin = Open3.capture3(env, binary, *args)
    same = ruby[0] == bin[0] && ruby[1] == bin[1] && ruby[2].exitstatus == bin[2].exitstatus
    puts "#{same ? 'same' : 'DIFF'}  exit #{ruby[2].exitstatus}  #{ruby[0].lines.size} lines  #{args.join(' ')}"
    unless same
      %w[stdout stderr].each_with_index do |name, i|
        next if ruby[i] == bin[i]

        r = ruby[i].lines
        b = bin[i].lines
        at = r.each_index.find { |j| r[j] != b[j] } || r.size
        puts "  #{name} first differs at line #{at + 1}:", "  ruby:   #{r[at].to_s[0, 300]}", "  binary: #{b[at].to_s[0, 300]}"
      end
      puts "  exit: ruby #{ruby[2].exitstatus}, binary #{bin[2].exitstatus}" if ruby[2].exitstatus != bin[2].exitstatus
    end
    !same
  end

  puts "#{cases.size - failures}/#{cases.size} cases identical"
  exit(failures.zero? ? 0 : 1)
end
