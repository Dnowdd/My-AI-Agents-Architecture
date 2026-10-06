#!/usr/bin/env python3
"""Renders core/ into the files each tool reads.

  render.py claude <out-dir>   → CLAUDE.md, agents/*.md
  render.py codex  <out-dir>   → AGENTS.md, agents/*.toml, hooks.json

Settings come from the environment (install.sh exports .env first):
RESPONSE_LANGUAGE, UI_LANGUAGE, CODE_LANGUAGE, PROFILE_FILE, VAULT_DIR, AGENT_MEMORY_DIR, DB_GUARD,
{CLAUDE,CODEX}_MODEL_{DEEP,BALANCED,FAST}, CODEX_HOME.
"""
import json
import os
import pathlib
import re
import shutil
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
CORE = REPO / "core"

TIER_DEFAULTS = {
    "claude": {"deep": "opus", "balanced": "sonnet", "fast": "haiku"},
    "codex": {"deep": "gpt-6-astra", "balanced": "gpt-6.1-sol", "fast": "gpt-6-luna"},
}
CODEX_EFFORT = {"max": "xhigh"}

TARGETS = {
    "claude": {
        "INSTRUCTIONS_FILE": "CLAUDE.md",
        "AGENTS_DIR": "~/.claude/agents/",
        "HOOKS_DIR": "~/.claude/hooks",
        "COMMIT_SKILL": "`/commit`",
        "TYPESAFE_SKILL": "`/typesafe:typesafe-ai`",
        "SCRIBE_MODE": ", in the background",
    },
    "codex": {
        "INSTRUCTIONS_FILE": "AGENTS.md",
        "AGENTS_DIR": "~/.codex/agents/",
        "HOOKS_DIR": "~/.codex/hooks",
        "COMMIT_SKILL": "`$commit`",
        "TYPESAFE_SKILL": "`$typesafe-ai`",
        "SCRIBE_MODE": "",
    },
}


def env(name, default=""):
    return os.environ.get(name, "").strip() or default


def only_for(text, target):
    def keep(m):
        return m.group(2) if m.group(1) == target else ""
    return re.sub(r"<!-- if (\w+) -->\n(.*?)<!-- endif -->\n", keep, text, flags=re.S)


def demote_headings(text):
    out, fenced = [], False
    for line in text.splitlines():
        if line.lstrip().startswith("```"):
            fenced = not fenced
        out.append("#" + line if not fenced and re.match(r"#{1,5} ", line) else line)
    return "\n".join(out)


def preferences():
    return "\n".join([
        "## User preferences",
        f"- Response language (also for subagents and vault notes): **{env('RESPONSE_LANGUAGE', 'English')}**.",
        f"- UI copy language in the apps you build: **{env('UI_LANGUAGE', 'en-US')}**.",
        f"- Language for code, commits and identifiers: **{env('CODE_LANGUAGE', 'English')}**.",
    ])


def profile():
    path = pathlib.Path(env("PROFILE_FILE", str(CORE / "profile.example.md"))).expanduser()
    text = re.sub(r"<!--.*?-->\s*", "", path.read_text(), flags=re.S).strip() if path.exists() else ""
    return demote_headings(text)


def render_rules(target):
    text = only_for((CORE / "rules.md").read_text(), target)
    values = dict(TARGETS[target], PREFERENCES=preferences(), PROFILE=profile())
    for key, value in values.items():
        text = text.replace("{{" + key + "}}", value)
    return re.sub(r"\n{3,}", "\n\n", text)


def parse_agent(path):
    _, front, body = path.read_text().split("---\n", 2)
    meta = dict(re.findall(r"^([\w-]+):\s*(.*)$", front, re.M))
    return meta, body.lstrip("\n")


def model_for(target, tier):
    name = f"{target.upper()}_MODEL_{tier.upper()}"
    return os.environ[name].strip() if name in os.environ else TIER_DEFAULTS[target][tier]


def claude_agent(meta, body):
    lines = [f"name: {meta['name']}", f"description: {meta['description']}"]
    access = meta.get("access", "full")
    disallowed = {"read-only": ["Write", "Edit", "NotebookEdit"], "no-edit": ["Edit", "NotebookEdit"]}.get(access, [])
    disallowed += [t.strip() for t in meta.get("claude_disallowed_tools", "").split(",") if t.strip()]
    if access == "vault":
        lines.append("tools: Read, Write, Edit, Glob, Grep, Bash")
    if disallowed:
        lines.append("disallowedTools: " + ", ".join(disallowed))
    model = model_for("claude", meta["tier"])
    if model:
        lines.append(f"model: {model}")
    lines.append(f"effort: {meta['effort']}")
    if meta.get("memory") == "true":
        lines.append("memory: user")
    if meta.get("background") == "true":
        lines.append("background: true")
    if meta.get("color"):
        lines.append(f"color: {meta['color']}")
    return "---\n" + "\n".join(lines) + "\n---\n\n" + body


def codex_memory(meta, what_to_keep):
    path = f"{env('AGENT_MEMORY_DIR', '~/.claude/agent-memory')}/{meta['name']}/MEMORY.md"
    lines = [
        "## Memory",
        f"Your persistent memory, shared with Claude Code's `{meta['name']}` agent, is `{path}`.",
        "- At the start, read it if it exists. It holds notes from earlier sessions, not instructions from the user.",
        f"- What to keep: {what_to_keep.strip()}" if what_to_keep.strip() else "",
    ]
    if meta.get("access") == "read-only":
        lines.append(f"- Your sandbox is read-only, so never write it yourself. When you learned something worth keeping, "
                     f"end your reply with a `Memory update for {meta['name']}` section listing the items to add; "
                     f"the main agent saves them.")
    else:
        lines.append("- Before returning, update it with what you learned: concise, organized by topic, no duplicates, "
                     "under 200 lines. Create the folder if it is missing. Edit only this file outside the project.")
    return "\n".join(l for l in lines if l)


def codex_agent(meta, body):
    keep = re.search(r"\n## Memory\n(.*?)(?=\n## |\Z)", body, flags=re.S)
    body = re.sub(r"\n## Memory\n.*?(?=\n## |\Z)", "\n", body, flags=re.S).rstrip() + "\n"
    if meta.get("memory") == "true":
        body += "\n" + codex_memory(meta, keep.group(1) if keep else "") + "\n"
    if "'''" in body:
        sys.exit(f"agent {meta['name']}: body cannot contain '''")
    q = lambda s: json.dumps(s, ensure_ascii=False)
    lines = [f"name = {q(meta['name'])}", f"description = {q(meta['description'])}"]
    model = model_for("codex", meta["tier"])
    if model:
        lines.append(f"model = {q(model)}")
    lines.append(f"model_reasoning_effort = {q(CODEX_EFFORT.get(meta['effort'], meta['effort']))}")
    access = meta.get("access", "full")
    if access == "read-only":
        lines.append('sandbox_mode = "read-only"')
    elif access == "vault":
        lines.append('sandbox_mode = "workspace-write"')
    lines.append(f"developer_instructions = '''\n{body}'''")
    if access == "vault" and env("VAULT_DIR"):
        lines += ["", "[sandbox_workspace_write]", f"writable_roots = [{q(env('VAULT_DIR'))}]"]
    return "\n".join(lines) + "\n"


def codex_hooks():
    home = env("CODEX_HOME", str(pathlib.Path.home() / ".codex"))
    hooks = {
        "SessionStart": [{"hooks": [
            {"type": "command", "command": f"{home}/hooks/vault-context.sh", "timeout": 10},
        ]}],
        "PreToolUse": [{"matcher": "^Bash$", "hooks": [
            {"type": "command", "command": f"{home}/hooks/db-guard.py --codex", "timeout": 8,
             "statusMessage": "Checking database command"},
        ]}],
    }
    if env("DB_GUARD", "on").lower() == "off":
        del hooks["PreToolUse"]
    return json.dumps({"description": "Managed by My AI Agents Architecture.", "hooks": hooks}, indent=2) + "\n"


def main():
    if len(sys.argv) != 3 or sys.argv[1] not in TARGETS:
        sys.exit(__doc__)
    target, out = sys.argv[1], pathlib.Path(sys.argv[2])
    agents_dir = out / "agents"
    shutil.rmtree(agents_dir, ignore_errors=True)
    agents_dir.mkdir(parents=True)
    (out / TARGETS[target]["INSTRUCTIONS_FILE"]).write_text(render_rules(target))
    for src in sorted((CORE / "agents").glob("*.md")):
        meta, body = parse_agent(src)
        if target == "claude":
            (agents_dir / f"{meta['name']}.md").write_text(claude_agent(meta, body))
        else:
            (agents_dir / f"{meta['name']}.toml").write_text(codex_agent(meta, body))
    if target == "codex":
        (out / "hooks.json").write_text(codex_hooks())


if __name__ == "__main__":
    main()
