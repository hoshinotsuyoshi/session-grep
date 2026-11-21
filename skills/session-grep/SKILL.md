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
session-grep --list --cwd example-app-02 --since 7d      # recent sessions in a directory, no word needed
```

- Words are fixed strings, not regular expressions. `-i` ignores case. Multiple words are ANDed (every word appears somewhere in the session's shown messages, not necessarily on the same line). Non-ASCII words such as Japanese work the same way.
- `--repo` / `--cwd`: only sessions whose cwd contains the string. Default is all repos. It matches the cwd the session started in, so a session started in another repo's cwd that touched, say, dotfiles is missed by `--repo dotfiles`. To avoid missing it, search by words without narrowing.
- `--since` / `--until`: filter by the log's mtime (`3d`, `12h`, `2w`, `2026-10-01`). Common words can take a few seconds across all logs, so narrow by time or repo.
- `--tool claude|codex`: only one of them.
- `--limit N`: the newest N sessions.
- Order: sessions are oldest first by their last message (human / hc / agent), newest at the bottom. The heading time is that time too; if the log was updated later, `(log 16:10)` is added. Matching messages are in time order within a session.
- Times are `HH:MM`. A line whose date differs from the heading or the previous line shows `MM-DD HH:MM`.
- The session doing the search (`$CLAUDE_CODE_SESSION_ID`) is excluded by default (`--include-self` shows it). When calling from codex, or to exclude other sessions, use `--exclude-session <id prefix>`.

## Calling it from an agent

- Give at least one word. `--repo` / `--since` alone is a usage error: exit 2, one line on stderr, nothing on stdout. To see what happened in a directory without a word, use `--list` (below).
- Exit status: 0 = found, 1 = nothing found, 2 = usage error. Check it, or use `2>&1`. Don't add `2>/dev/null`: with it, a usage error or a broken jq filter looks the same as "no sessions found".
- `--json` prints JSON Lines: one object per line, not an array. Read it with `jq -r '.session_id'`, not `.[]`. One line looks like this (`hits` shortened):

  ```json
  {"tool":"claude","session_id":"0b9e2c4a-5d7f-4e1b-9a3c-6f2d8e7b1c05","cwd":"/Users/me/src/example-app-01","cwd_exists":true,"branch":"main","started_at":"2026-01-10T09:00:00.000Z","last_message_at":"2026-01-12T05:30:00.000Z","updated_at":"2026-01-12T05:30:01Z","title":"Fix login redirect","first_prompt":"...","forked_from":null,"hits":[{"kind":"human","ts":"2026-01-10T09:05:00.000Z","text":"who was working on PR 482?"}],"hit_counts":{"human":2,"agent":3,"tool":9},"subagents":[],"resume":"cd /Users/me/src/example-app-01 && claude --resume 0b9e2c4a-5d7f-4e1b-9a3c-6f2d8e7b1c05","path":"/Users/me/.claude/projects/.../0b9e2c4a-5d7f-4e1b-9a3c-6f2d8e7b1c05.jsonl"}
  ```

  The session's times are `started_at`, `last_message_at` and `updated_at`. `ts` and `text` exist only inside `hits[]`. There is no `summary`, `snippet`, `started` or `last_ts`; use only the keys listed under "Main JSON keys".

  ```sh
  session-grep 482 example-app --since 3w --json | jq -r '[.session_id[0:8], .last_message_at, .title] | @tsv'
  session-grep 482 example-app --since 3w --json | jq -r '.hits[] | select(.kind == "human") | .text'
  ```

- `--show ID --json`: the first line is the session (the same keys as a search result, without `hits` and `hit_counts`), and each following line is one message `{kind, ts, text}`.
- `--list --cwd DIR --since 7d [--json]`: the sessions in that directory and period, newest at the bottom, without searching for a word (`hits` is empty). Use it to see recent work in a clone before reusing it. `--list` needs `--cwd`, `--since` or `--until`.

## Choosing words

- For an issue or PR, search the number and the repo name as two words (`4821 example-app`), not the URL or `repo#4821`. Logs write the same issue in several forms (URL, `owner/repo#N`, `#N`), and a single form misses the others.
- Ids and names work well: Artifact ids, hc terminal names (`review-42`), branch names, rare product or tool names.
- Use the word you already have (an issue number, a PR number) even when you also know the directory; `--cwd` alone lists, it doesn't answer "who did X".
- When nothing matches: drop a word, add `--all` (to also search tool input and output), or widen `--since`.

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
