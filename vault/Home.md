---
tags: [moc]
---
# Claude Brain

Long-term memory for Claude Code agents. The **scribe** agent does most of the writing. You read, edit and fix notes freely, and your version always wins.

From the shell, the vault is reachable at `~/claude-brain`.

## Structure

| Folder | What goes there | File name |
|---|---|---|
| [[Projects]] | One living note per project: stack, current state, next steps, pitfalls | `<repo-folder-name>.md` |
| [[Decisions]] | Technical decisions and their reasons (ADR-style) | `YYYY-MM-DD <project> - <title>.md` |
| [[Sessions]] | Short logs of sessions that changed something | `YYYY-MM-DD <project> - <topic>.md` |
| [[Knowledge]] | Learnings that apply to any project (gotchas, recipes) | `<topic>.md` |
| [[Inbox]] | Loose ideas to organize later | free |
| [[Templates]] | Templates for the notes above (`Project`, `Decision`, `Session`) | — |

You can rename the folders, for example to translate them. If you do, update this table so the scribe follows it, and set `VAULT_PROJECTS_DIR` in My AI Agents Architecture's `.env` so the session hook finds the project notes.

## How it reaches Claude

- When a Claude Code session starts inside a git repo, a hook reads the project note for that repo and injects it into the context.
- After meaningful work, Claude asks the **scribe** to update the project note and record decisions and sessions.
- Behavior rules ("never commit with co-authors") live in `~/.claude/CLAUDE.md` and Claude's auto-memory, not here. This vault holds **context**: what exists, what was decided, where work stopped.
