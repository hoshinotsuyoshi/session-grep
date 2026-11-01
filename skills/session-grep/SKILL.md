---
name: session-grep
description: Search past Claude Code and codex sessions (the jsonl files in ~/.claude/projects and ~/.codex/sessions) for words, and show which session talked about what, its cwd, branch, and resume command. Use when asked "which session was that in?", "find the session where I looked into X", "search past logs for X", "I need the id for claude --resume", or when an agent wants to check past context. Also for Japanese requests such as 「あの話どのセッションでしたっけ」「前に〜を調べたセッションを探して」「過去ログから〜を探して」「claude --resume する id を知りたい」.
---

# session-grep: search past sessions

`session-grep` (needs rg, and Ruby 3.4+ unless the prebuilt binary is installed) searches Claude Code and codex logs together. The tool is `bin/session-grep` in this repo or the prebuilt binary from a release, and should be on your PATH (see Install in the README). If it isn't found, check `command -v session-grep` and ask the human to install it.

## Usage

```sh
session-grep maintenance --repo example-org --since 3d   # for humans
session-grep maintenance --repo example-org --json       # for agents (JSON Lines, one session per line)
session-grep zprofile rbenv --since 2d                   # multiple words are ANDed (same as -e zprofile -e rbenv)
session-grep --show 1234abcd                             # one session's human and agent messages in time order
```

- Words are fixed strings, not regular expressions. `-i` ignores case. Multiple words are ANDed (every word appears somewhere in the session's shown messages, not necessarily on the same line). Non-ASCII words such as Japanese work the same way.
- `--repo` / `--cwd`: only sessions whose cwd contains the string. Default is all repos. It matches the cwd the session started in, so a session started in another repo's cwd that touched, say, dotfiles is missed by `--repo dotfiles`. To avoid missing it, search by words without narrowing.
- `--since` / `--until`: filter by the log's mtime (`3d`, `12h`, `2w`, `2026-10-01`). Common words can take a few seconds across all logs, so narrow by time or repo.
- `--tool claude|codex`: only one of them.
- `--limit N`: the newest N sessions.
- Order: sessions are oldest first by their last message (human / hc / agent), newest at the bottom. The heading time is that time too; if the log was updated later, `(log 16:10)` is added. Matching messages are in time order within a session.
- Times are `HH:MM`. A line whose date differs from the heading or the previous line shows `MM-DD HH:MM`.
- The session doing the search (`$CLAUDE_CODE_SESSION_ID`) is excluded by default (`--include-self` shows it). When calling from codex, or to exclude other sessions, use `--exclude-session <id prefix>`.

## Kinds of matching lines

| kind | contents | default |
|---|---|---|
| `human` | human input (typed in Claude, role=user in codex) | shown |
| `hc` | messages between agents (`<hc from=...>`, `<hc>` notifications, `<teammate-message>`, SendMessage) | shown |
| `agent` | the agent's reply text | shown |
| `tool` | tool input and output | count only |
| `thinking` | thinking / reasoning | count only |
| `meta` | skill list, CLAUDE.md, AGENTS.md, ai-title, metadata (cwd etc.), `<system-reminder>` in front of human input | counted, not shown |

Sessions with no match in `human` / `hc` / `agent` are not shown. Skill names and the like appear in every session as meta, so this drops them. To search inside tool output, use `--all`.

A session forked in Claude holds copies of the original's lines with `forkedFrom`. Copied lines are not counted, and `fork of: <original id>` is shown (the same content doesn't appear twice).

Matches in subagent logs (Claude's `<session>/subagents/`) are merged into the parent session with an `agent_id` (`--no-subagents` leaves them out). codex review subagent sessions are included by default.

## Main JSON keys

`tool`, `session_id`, `cwd`, `cwd_exists`, `branch`, `started_at`, `last_message_at`, `updated_at`, `forked_from`, `title`, `first_prompt`, `hits[] {kind, ts, text, agent_id?}`, `hit_counts`, `subagents`, `resume`, `path`.

## Resume

`resume` is `cd <cwd> && claude --resume <id>` / `cd <cwd> && codex resume <id>`. When the cwd is gone (e.g. a deleted worktree), `cwd_exists` is `false`. Agents don't resume on their own; hand the command to the human.
