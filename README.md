# session-grep

A CLI that searches past Claude Code and codex session logs (the jsonl files under `~/.claude/projects` and `~/.codex/sessions`) for words. For each matching session it prints the cwd, branch, title, first prompt, matching messages, and the command to resume it (`claude --resume <id>` / `codex resume <id>`).

It answers "which session was that conversation in?". It also works as a Claude Code skill.

## Features

- Multiple words are ANDed (all of them must appear somewhere in the same session, not necessarily on the same line)
- By default it looks only at human input, agent replies, and messages between agents. Tool input/output and thinking are only counted (`--all` shows them too)
- Narrow with `--repo` (substring of the cwd), `--since` / `--until`, and `--tool claude|codex`
- `--json` prints JSON Lines, one session per line (for agents)
- `--show <id>` prints one session's messages in time order
- Subagent logs are merged into their parent session. Lines copied into a forked session are not counted twice
- The session doing the search (`$CLAUDE_CODE_SESSION_ID`) is excluded by default
- Any language works: words are matched as plain strings, so Japanese and other non-ASCII words work the same as English

## Requirements

- [ripgrep](https://github.com/BurntSushi/ripgrep) (`rg`)
- Either the prebuilt binary (macOS arm64, Linux x86_64) or Ruby 3.4 or later (standard library only, no gems)

## Install

### Prebuilt binary

Each release has an archive per platform with the `session-grep` binary, `LICENSE`, and `THIRD_PARTY_NOTICES`. Download it from the [Releases](https://github.com/hoshinotsuyoshi/session-grep/releases) page, or with [gh](https://cli.github.com/):

```sh
gh release download --repo hoshinotsuyoshi/session-grep --pattern '*-darwin-arm64.tar.gz' --pattern SHA256SUMS
shasum -a 256 --ignore-missing -c SHA256SUMS
tar xzf session-grep-*-darwin-arm64.tar.gz
install -m 755 session-grep-*-darwin-arm64/session-grep ~/.local/bin/session-grep   # anywhere on your PATH
```

On Linux, use `'*-linux-x86_64.tar.gz'` and `sha256sum --ignore-missing -c SHA256SUMS`. The Linux binary links glibc dynamically and needs glibc 2.34 or later (Ubuntu 22.04, Debian 12, RHEL 9 and newer).

The binary is compiled from `bin/session-grep` with [Spinel](https://github.com/matz/spinel) (the version is in `.spinel-version`), and CI checks that it gives the same output as the script. It starts in about 4 ms instead of about 40 ms, and `--show` is about 3.5x faster, but searches are only 1.1-1.4x faster: most of their time goes to reading and parsing the matching log lines. (Measured on about 1.8 GB of real logs on macOS arm64 with Ruby 3.4.4 and 4.0.7: logs in the page cache, median of 7 runs, 7 sets of arguments.)

### From source (Ruby)

```sh
git clone https://github.com/hoshinotsuyoshi/session-grep.git
ln -s "$PWD/session-grep/bin/session-grep" ~/.local/bin/session-grep   # anywhere on your PATH
```

## Usage

```sh
session-grep maintenance --repo example-org --since 3d   # for humans
session-grep maintenance --repo example-org --json       # for agents (JSON Lines)
session-grep zprofile rbenv --since 2d                   # multiple words are ANDed
session-grep --show 1234abcd                             # one session's messages in time order
session-grep --help
```

Words are fixed strings, not regular expressions. Common words can take a few seconds across all logs, so narrow by time or repo.

`--repo` matches the cwd the session was started in. A session started in another directory that touched this repo is not included; search without `--repo` if you don't want to miss it.

## Use as a Claude Code skill

Put `skills/session-grep/SKILL.md` in your Claude Code skills directory, and Claude will call `session-grep` when you ask things like "find the session where I looked into X". Put `session-grep` (the binary or `bin/session-grep`) on your PATH first.

```sh
ln -s "$PWD/session-grep/skills/session-grep" ~/.claude/skills/session-grep
```

## Test

```sh
ruby test/session_grep_test.rb
SG_BIN=/path/to/session-grep ruby test/session_grep_test.rb   # run the CLI tests against a compiled binary
ruby test/compare_binary.rb /path/to/session-grep             # same output as the script on synthetic logs
ruby test/perf.rb /path/to/session-grep                       # timings; fails if the binary is over 1.5x slower
```

Tested with Ruby 3.4.4 and 4.0.7.

## Similar tools

Other tools can also search past Claude Code and codex sessions.

- [memex](https://github.com/nicosuave/memex) searches an index (BM25, plus semantic search if you build embeddings). It has a CLI, a TUI, and MCP, and overlaps with session-grep in several ways, such as merging subagents into the parent session and not counting history copied by forks.
- [cass](https://github.com/Dicklesworthstone/coding_agent_session_search) is a TUI and CLI backed by a SQLite index. It supports more than 30 agents.
- [recall](https://github.com/zippoxer/recall) is a full-text search TUI. It also has `recall search` for agents.

session-grep builds no index (no database, no daemon) and reads the jsonl files directly with rg every time. It depends only on the Ruby standard library and rg, and the whole tool is the single file `bin/session-grep` (the prebuilt binaries are compiled from it).

## License

MIT

The prebuilt binaries also contain the Spinel runtime and parts of the libraries Spinel compiles into them; their licenses are in [THIRD_PARTY_NOTICES](THIRD_PARTY_NOTICES).
