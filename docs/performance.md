# Performance notes

These notes record where a search spends its time, what was tried to make it faster, which changes were kept, and the numbers behind them. Every number is a measurement unless it is marked as an estimate.

## How the numbers were taken

- macOS arm64 (12 cores), Ruby 3.4.4 and 4.0.7, rg 14.1.1.
- Real logs: about 2.2 GB, made up of about 1.6 GB of Claude Code logs (806 files, parents and subagents) and about 610 MB of codex logs (839 files). The README's earlier numbers were taken on about 1.8 GB of the same kind of logs.
- The logs were in the page cache: each case first ran once with every configuration being compared, and those runs were not counted.
- The configurations ran alternately (in one order on even runs, in reverse on odd runs), and each time is the median of the runs. The release tables use 7 runs. The quick before/after tables use 3.
- The machine was not idle. Each table gives its load average where it was recorded, which was between 2 and 10. With a load near 10, times varied by about 30%, so compare columns within one table, not across tables.
- The search words are ordinary ones that are rare or common in these logs: `spinel` (rare), `README` and `test` (common), and an invented word with no hits.

### Reproducing

There is no script in the repo for real logs, because their size and content differ on every machine. To repeat a table:

1. Get the binaries to compare with `gh release download <tag> --pattern '*-darwin-arm64.tar.gz' --pattern SHA256SUMS`, and the script for a tag with `git show <tag>:bin/session-grep`.
2. Run each configuration once per set of arguments to warm the page cache. Then run them alternately N times, and take the median of each. Set `CLAUDE_CODE_SESSION_ID` to your own session, or to empty, so that every configuration searches the same files.
3. Check that the outputs are identical before comparing times. Use `--until` a few minutes in the past, so that logs being written do not change between runs.

`test/perf.rb` is a different check. It times the script and a binary on synthetic logs (about 170 MB at the default scale), and fails only when the binary is more than 1.5x slower than the script. It guards against a Spinel build that is much slower. It is not meant to give the absolute numbers in this document, because the synthetic logs have none of the huge tool-output lines that dominate real logs.

## Where the time goes

### Before v0.1.4 (547545d, Ruby 3.4.4, seconds)

At the time, rg listed the files containing each word (`rg -l`, once per word), and Ruby then read every line of those files. The table was measured by timing each method of the script.

| args | total | scan_file | read_meta | JSON.parse (in both) | classify | rg | last_message_at |
|---|---|---|---|---|---|---|---|
| a word with no hits | 1.09 (rg cold) | 0.00 | 0.00 | 0.00 | 0.00 | 1.00 | 0.00 |
| `spinel` | 1.12 | 0.55 | 0.31 | 0.15 | 0.02 | 0.22 | 0.01 |
| `README` | 9.17 | 5.95 | 2.86 | 1.22 | 0.25 | 0.10 | 0.14 |
| `test` | 9.19 | 6.60 | 2.13 | 2.43 | 0.51 | 0.09 | 0.25 |

- For a common word, the files rg keeps are 93-100% of all the logs (2073 MB of 2239 MB for `README`). The narrowing does almost nothing.
- Splitting those files into lines with `File.foreach` alone took 2.3-2.5 s. Adding the `include?` test made it 3.5-4.0 s.
- The lines containing the word were 345 MB for `README` and 946 MB for `test`, mostly huge tool results and request dumps. Parsing them all as JSON took 0.6-1.7 s.
- So JSON parsing was only 13-25% of the time. Most of it went to Ruby reading whole files twice: once in `scan_file`, and once more in `read_meta`. `read_meta` kept reading to the end of every file to find the `ai-title` line, even after it had found the cwd, the branch and the first prompt.
- rg itself took 0.03-0.1 s when warm.

### Shape of the logs

- In Claude Code logs, user lines holding a tool_result are 34% of the bytes, and API and attachment dumps are another 30% or so. The text of the messages the default search shows (human, hc and agent) adds up to about 24 MB, 1.1% of all the logs. Tool text is about 361 MB.
- In a Claude Code line, the top-level `"type"` comes early for user lines (the fourth key), but after the whole message for assistant lines, near the end. So a test on the start of a line cannot tell an assistant line.
- In a codex line, the top-level `"type"` comes before the payload. Newer codex versions put an `"ordinal"` key between `"timestamp"` and `"type"`, so a check that assumes a fixed key order breaks. It did break in a prototype.
- Inside a JSON string, a `"` is always escaped. So a line without a bare `"type":"user"` cannot have `user` as its top-level type. The reverse does not hold, since the substring can come from a nested object, but such a line is parsed and nothing is lost.

## Tried and not kept

- **Scanning the files without rg.** A Spinel program that reads each file whole and calls `String#index` took 0.7-1.6 s over 1378 files. `rg -l` took 0.03-0.06 s for the same files. rg runs in parallel, uses SIMD, and with `-l` moves on at a file's first match. The Ruby script was no faster than the Spinel program, because reading and `memchr` are the limit. Since rg was never the slow part, replacing it was dropped.
- **Skipping huge lines.** After the changes below, this would save little. Human messages with pasted images reach 1.5 MB, so any size limit risks missing them.
- **rg `--max-columns`.** It hides the text of long lines, which would drop long human messages.

## Kept changes and their numbers

### v0.1.4: read only matching lines (d21c698)

- One rg run (`-F -H --null`, every word as `-e`) prints the matching lines with their file, so Ruby never reads the rest of a file.
- Unless meta is shown, lines that cannot be a message are counted as meta without JSON parsing:
  - For Claude Code, a compact line without `"type":"user"`, `"type":"assistant"` or `forkedFrom`.
  - For codex, a line whose top-level type, read from the start of the line, is not `response_item` (`event_msg` lines are skipped, as before).
  - A line that does not end in `}` is still parsed, so a line being written is not counted.
- `read_meta` stops once the cwd, the branch and the first prompt are known. Titles come from one rg run over all the files (the last `ai-title` line wins, as before).

Times with the Spinel d2449044a build, 3 runs each, load 2.5-4 (seconds):

| args | old script | old binary | new script | new binary |
|---|---|---|---|---|
| `README` | 5.91 | 4.16 | 1.52 | 1.52 |
| `test` | 7.80 | 6.68 | 3.68 | 3.68 |
| `README test` | 9.05 | 7.08 | 4.91 | 4.23 |
| `--all README` | 14.17 | 7.49 | 9.98 | 5.32 |
| `--list --since 3d` | 0.44 | 0.33 | 0.17 | 0.15 |

The output was the same as before on 13 sets of arguments (text, `--json`, `--all`, `-i`, AND, `--list`, `--no-subagents`, `--tool codex`) and three `--show` runs. Each was compared for the old script, the new script and the new binary.

### The v0.1.4 regression and its fix in v0.1.5 (cda5d65)

Passing every word to one rg run removed the per-word narrowing. A common word ANDed with a rare one made rg print the common word's lines from every file, although the rare word leaves only a few sessions. v0.1.5 runs `rg -l` per word first, when there are two or more words, and sends only the files of sessions that have every word to the line pass. One word runs no extra rg.

Binary times, 3 runs each (seconds):

| args | v0.1.1 | v0.1.4 | v0.1.5 |
|---|---|---|---|
| `spinel README` | 0.67 | 1.92 | 0.42 |
| `--all --json spinel README` | 0.94 | 5.57 | 0.74 |
| `--since 30d README test` | 5.86 | 3.60 | 3.75 |
| `-i spinel` | 0.95 | 0.34 | 0.33 |
| `--all -i readme` | 17.33 | 10.24 | 10.34 |

When both words are common, the extra `rg -l` runs cost about 4% (0.15 s).

### Release comparison, 7 runs each (seconds)

The same 7 kinds of arguments as the README's earlier measurement: `--help`, a word with no hits, `-i` with one word, two words with `--since 30d`, `--show ID --full`, `--all -i` with one word, and `--all --json` with two words. The exact words of the earlier run were not kept, so these use the words above. `--show` reads one Claude Code session of 4-8 MB.

v0.1.4, load 2.0-2.3:

| args | script, Ruby 3.4.4 | script, Ruby 4.0.7 | v0.1.4 binary | v0.1.1 binary |
|---|---|---|---|---|
| `--help` | 0.038 | 0.039 | 0.004 | 0.003 |
| no hits | 0.150 | 0.151 | 0.101 | 0.136 |
| `-i spinel` | 0.407 | 0.378 | 0.339 | 0.950 |
| `--since 30d README test` | 3.922 | 3.603 | 3.604 | 5.827 |
| `--show ID --full` | 0.075 | 0.074 | 0.038 | 0.037 |
| `--all -i readme` | 16.182 | 13.020 | 10.151 | 16.445 |
| `--all --json spinel README` | 10.448 | 7.381 | 5.430 | 0.954 |

v0.1.5, load 1.8-2.4:

| args | script, Ruby 3.4.4 | script, Ruby 4.0.7 | v0.1.5 binary | v0.1.1 binary |
|---|---|---|---|---|
| `--help` | 0.038 | 0.040 | 0.003 | 0.003 |
| no hits | 0.143 | 0.143 | 0.100 | 0.126 |
| `-i spinel` | 0.399 | 0.382 | 0.336 | 0.955 |
| `--since 30d README test` | 4.095 | 3.731 | 3.686 | 5.938 |
| `--show ID --full` | 0.080 | 0.076 | 0.040 | 0.039 |
| `--all -i readme` | 16.873 | 13.406 | 10.620 | 17.621 |
| `--all --json spinel README` | 1.148 | 0.897 | 0.730 | 0.939 |

From the v0.1.5 table:
- The binary starts in about 3-4 ms instead of about 40 ms.
- `--show` is 1.9-2.0x faster with the binary.
- Searches are 1.0-1.6x faster with the binary than with the script.
- Against v0.1.1's binary, searches are 1.3-2.8x faster.

With v0.1.5 a search is limited by rg and by parsing the lines rg prints, so the binary gains little over the script.

## Not tried yet: a cache built from logs that only grow

A prototype, outside the repo, kept per log file the extracted text and the offset read so far. On each run it parsed only the bytes added since. These are prototype measurements on the same logs:

| | measured |
|---|---|
| first build (parse every line, Ruby) | 7.9 s |
| check when nothing changed (stat every file) | 0.05 s |
| update after two files grew | 0.07 s |
| cache size | 25.6 MB of message text + 380 MB of tool and thinking text (18% of the logs) |
| search for `test` in the message text, parsing only the hits | 0.05 s |

Estimate (not measured): with the session info (cwd, branch, title, first prompt, last message time) in the cache too, a default search would take 0.2-0.4 s.

Open problems:
- It assumes that Claude Code and codex only append to their logs. This was not verified. Shrinking or a changed head of a file can be detected, but a rewrite in the middle cannot.
- `hit_counts.meta` in `--json`, and the rule that a line matching only in metadata (cwd and so on) counts as meta, both need the raw lines. A cache of extracted text cannot give exactly the same counts.
- Counting tool hits with `rg -c` on JSON-encoded text miscounts words with `"` or `\`, and words that are also key names.
- `--all` would still have to read the raw logs.
- It adds state to maintain: a cache directory, concurrent updates (write a temporary file and rename it), and removal of entries for deleted logs.

## Spinel notes found along the way

- With Spinel d2449044a, an `each_slice` block parameter was not a GC root. A collection could free the slice while rg's arguments were being built, and the binary looped forever. 547545d replaced `each_slice` with a `while` loop over a plain local, which the rg helpers still use. matz/spinel@3a2d0d40d fixed this.
- With Spinel d2449044a, when every Set in a program came from a bare `Set.new`, sets were freed while still in use (caught by `SPINEL_GC_STRESS=2`). Spinel 5f01c67fc fixed this. `candidate_files` still builds its sets with `to_set` and a block.
- With Spinel 5f01c67fc, `reject!` or `select!` on an Array built by `flat_map` gives the block parameter the C type `const char *`, and the C fails to compile. The script uses the non-bang `reject` instead. This was reported as [matz/spinel#12370](https://github.com/matz/spinel/issues/12370). It was fixed on Spinel's master in 455f98808 (as of 2026-11-22), which is not yet in the version `.spinel-version` names (5f01c67fc).
- Spinel 5f01c67fc's `make` builds its bundled sqlite3 extension, which fails to link with the libsqlite3 3.37 of Ubuntu 22.04. `script/build-spinel.sh` passes `SQLITE3_AVAILABLE=no`.
