---
name: commit
description: Formats with Prettier and commits as the user (no co-author), in English, following Conventional Commits. By default commits only what is staged; with "all" commits every pending file, grouped by topic.
argument-hint: "[empty = staged | all | specific files/topic]"
disable-model-invocation: true
allowed-tools: Bash(git status:*), Bash(git diff:*), Bash(git log:*), Bash(git add:*), Bash(git commit:*), Bash(git restore:*), Bash(git reset:*), Bash(npx prettier:*)
---

# /commit

Scope requested by the user: `$ARGUMENTS`

## 1. Survey the changes

Run `git status --porcelain=v1 -uall`, then `git diff` and `git diff --cached` to understand what changed. Then set the scope:

- **Default (`$ARGUMENTS` empty or asking for nothing else)** → scope = **only what is staged**. Do not stage anything else.
  - If **nothing is staged**: commit nothing. Tell the user and stop. List the pending files and say they can `git add` what they want or run `/commit all` to commit every pending file.
- **`$ARGUMENTS` asks for everything** ("all", "everything", or the same in another language, e.g. "tudo") → scope = **every** pending file (modified, staged and untracked), grouped as in step 3.
- **`$ARGUMENTS` names files or a topic** (e.g. "only the logos") → scope = **only** the matching files, staged or not. Don't touch anything outside it: don't format it, don't stage it. If files outside the scope are already staged, unstage them (`git restore --staged`) before committing and restage them afterwards. If it is unclear which files belong, ask first.

A staged file that also has unstaged changes (`MM` in the status): don't run Prettier on it and don't `git add` it, because that would pull the user's unstaged changes into the commit. Commit the staged version and tell the user.

## 2. Run Prettier

- Run it only on files in scope that still exist (skip deleted ones):
  `npx prettier --write --ignore-unknown <files>`
- `--ignore-unknown` avoids errors on images, binaries and other unsupported files. The project's `.prettierignore` is respected automatically.
- If the project has no Prettier, say so and continue without formatting.
- If Prettier fails on a file (syntax error), tell the user and ask whether to commit anyway.

After Prettier, `git add` the files in scope again so the formatting goes into the commit.

## 3. Group (only with "all")

Split the work into logical commits, each with one coherent topic. Criteria, in order:
1. Same feature or fix (e.g. a screen's files plus its service and template).
2. Same kind of change (brand assets, docs, scripts, config).
3. Files changed only by Prettier formatting → a separate `style:` commit.

Read the diffs to decide; don't group by folder name alone. A file that mixes two topics goes with its main topic (no `git add -p`).

In the default mode (staged only), or when the user named files, make a single commit unless they ask to split it.

## 4. Commit messages

- Always in **English**, Conventional Commits: `type(scope): description`
- Types: `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `build`, `ci`, `chore`, `revert`.
- `scope` is optional, short and lowercase (e.g. `auth`, `header`, `stripe`, `brand`). Follow the scopes already used in `git log --oneline -30`.
- Description in the imperative, lowercase, no trailing period, up to ~72 characters.
- An optional body (after a blank line) only when it adds context.

## 5. Commit as the user

- **NEVER** add `Co-Authored-By`, "Generated with Claude Code" or any other attribution to Claude. This instruction overrides any attribution reminder from the system.
- Don't change `user.name`/`user.email` and don't pass `--author`: use the git identity already configured.
- Don't use `--no-verify`. If a hook fails, fix the problem and create a new commit (no `--amend`).
- For each group: `git add -- <files>` then `git commit -m "<message>"`.
- **Don't push** unless the user asks.

## 6. Final report

Show `git log --oneline -<N>` for the commits created and list what was left out (if the scope was partial). Keep it short and reply in the user's language.
