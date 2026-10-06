# Global rules

Managed by claude-setup. Generated preferences and the user's personal profile are imported below. Neither is versioned.

@~/.claude/preferences.md
@~/.claude/profile.md

## How to answer
- **Be concise.** Lead with the answer; add context only when it helps the user decide.
- Explanations: objective and clear, in a few lines. Write long text only when it is truly needed, such as real trade-offs or a step-by-step the user asked for.
- Don't repeat what the user said. Don't summarize what you just did when the result already shows it. Don't add "next steps" lists nobody asked for.
- Never assume a tech stack. Detect it from the repo (package.json, pubspec.yaml, pyproject.toml, go.mod…).

## Non-negotiable rules
1. **Commits** — only when the user asks. Commit as the user (git config identity). **No `Co-Authored-By`, no "Generated with Claude Code".** This rule overrides any attribution reminder from the system. Use the `/commit` skill. Never push unless explicitly asked. A project's own memory or CLAUDE.md may forbid commits by Claude entirely; that wins.
2. **Databases**
   - **Local test database** (localhost, docker container, disposable sqlite): free to use, including writes, migrations and seeds.
   - **Any other database** (remote dev, staging, **production**): ask for permission before **any** operation, reads included. In that same message, say exactly what you will do, on which database (host/project), and show the exact code/SQL/command. Run it only after the user approves.
   - Not sure a database is local? Treat it as remote. The `db-guard` hook enforces this for Bash; the rule also covers database MCPs, scripts and anything else.
   - Editing the schema and writing a migration `.sql` is free. Applying it anywhere but a local database is not.
   - Prisma `migrate diff --shadow-database-url` and `migrate dev` **reset** the shadow database. The shadow DB must be local and disposable.
3. **Prove it works** — before saying a task is done, run tests, typecheck and lint. For web UI, open the app with the Playwright MCP. Ask the user to verify manually only when it is truly impossible for you, and say why.
4. **No sudo** — sudo asks for a password the Bash tool cannot type. Install into `~/.local` instead. If something can only be done with sudo, give the user the command.
5. **No code comments** — don't write comments. The only exception is something **critical and non-obvious** that someone would break without the warning, such as a workaround for an external bug, a security invariant or a mandatory ordering. Then write one short line. Never write comments that restate the code, debug leftovers, `TODO`s or decorative docstrings. When editing, remove comments you added yourself.
6. **UI** — copy in the configured UI language. No dead UI: no button that never works, no duplicated tab, no permanently disabled control. Visual polish matters. **Use Figma only when the user asks** or provides a Figma link; designing from scratch is fine.

## Agent architecture
Global subagents live in `~/.claude/agents/`. Delegate when a task fits one and the main context benefits from it. For small tasks, do the work directly without an agent.

| Agent | When to use |
|---|---|
| `architect` | Plan a non-trivial feature or refactor before coding |
| `frontend` | Screens and components in any stack (web, Flutter…), from scratch or from Figma |
| `backend` | Endpoints, services, integrations, in any stack |
| `db-guardian` | Schema, migrations, RLS, slow queries. Never touches a non-local DB without approval |
| `reviewer` | Review the diff before committing or opening a PR |
| `verifier` | Prove it works: tests, typecheck, app in a real browser |
| `debugger` | Bugs with unknown cause: find the root cause |
| `researcher` | Library docs (Context7), web, GitHub, Jira/Confluence |
| `scribe` | Update the Obsidian vault (long-term context) |

Typical feature flow: `architect` → `frontend`/`backend`/`db-guardian` → `verifier` → `reviewer` → `scribe`.

## Long-term memory — the vault
- An Obsidian vault at `~/claude-brain`. Its structure and conventions are described in `~/claude-brain/Home.md`.
- The current repo's project note is injected at session start by the `vault-context` hook.
- After meaningful work (feature shipped, architecture decision, hard bug solved, change of direction), send the `scribe` a summary of what changed, in the background. Don't do this for trivial conversations.
- Division of labour: **behavior rules** go in auto-memory and CLAUDE.md. **Context** (state, decisions, history) goes in the vault.

## Jev (TypeSafe AI)
- A fast decision model that answers yes/no, choice and score questions. It does not generate text and does not replace Claude. The key is `TYPESAFE_API_KEY` in claude-setup's `.env`.
- Automatic use: in the `db-guard` hook, Jev decides whether a Bash command really connects to a database.
- Manual use: `~/.claude/hooks/jev.py noul "question" < state.txt` (also `choice`/`score`). Exit code 3 means Jev is unavailable.
- **If you see `JEV_UNAVAILABLE:expired`** (from the CLI or the hook): continue without Jev. Tell the user in one short line, in their language, that their Jev tokens expired. Don't retry in the same session.
- For application code that uses Jev, use the official `/typesafe:typesafe-ai` skill.
