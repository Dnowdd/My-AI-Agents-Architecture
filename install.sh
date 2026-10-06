#!/usr/bin/env bash
# My AI Agents Architecture installer: global rules, subagents, hooks, the commit skill, the
# Obsidian vault, MCP servers, skills and plugins, for Claude Code and Codex. Idempotent:
# re-running applies only what changed, including changes to .env.
#
#   ./install.sh            install / update everything
#   ./install.sh --offline  skip MCP servers, skills and plugins (local files and .env only)
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_HOME="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
ENV_FILE="$REPO/.env"
CONFIG_DIR="$HOME/.config/my-ai-agents"
OLD_CONFIG_DIR="$HOME/.config/claude-setup"
SECRETS="$CONFIG_DIR/secrets.env"
PROFILE="$CONFIG_DIR/profile.md"
BUILD="$REPO/build"
STAMP="$(date +%Y%m%d-%H%M%S)"
OFFLINE=0
[ "${1:-}" = "--offline" ] && OFFLINE=1

step() { printf '\n\033[1;36m▸ %s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }

# Points $2 at $1. Anything already there that is not a symlink is moved to $3 (a backup folder).
link() {
  local src="$1" dst="$2" backup="$3"
  mkdir -p "$(dirname "$dst")"
  if [ -L "$dst" ] && [ "$(readlink "$dst")" = "$src" ]; then ok "$dst (ok)"; return; fi
  if [ -L "$dst" ]; then
    rm "$dst"
  elif [ -e "$dst" ]; then
    mkdir -p "$backup"
    mv "$dst" "$backup/"
    warn "previous $(basename "$dst") moved to $backup"
  fi
  ln -s "$src" "$dst"
  ok "$dst → $src"
}

# Writes stdin to $1 only if the content changed. Prints "changed" or "unchanged".
write_if_changed() {
  local dst="$1" tmp
  tmp="$(mktemp)"; cat > "$tmp"
  if [ -f "$dst" ] && cmp -s "$tmp" "$dst"; then rm "$tmp"; echo unchanged
  else mkdir -p "$(dirname "$dst")"; mv "$tmp" "$dst"; echo changed; fi
}

step "Requirements"
for bin in git python3 node npx; do
  command -v "$bin" >/dev/null && ok "$bin" || { warn "missing $bin — install it and run again"; exit 1; }
done

step "Configuration (.env)"
if [ ! -f "$ENV_FILE" ]; then
  cp "$REPO/.env.example" "$ENV_FILE"
  warn ".env created from .env.example — fill it in and run ./install.sh again"
fi
added=$(python3 - "$REPO/.env.example" "$ENV_FILE" <<'PY'
import re, sys
example, env = open(sys.argv[1]).read().splitlines(), open(sys.argv[2]).read()
have = set(re.findall(r"^\s*([A-Z_][A-Z0-9_]*)=", env, re.M))
new = [l for l in example if (m := re.match(r"\s*([A-Z_][A-Z0-9_]*)=", l)) and m.group(1) not in have]
if new:
    with open(sys.argv[2], "a") as f:
        f.write("\n" + "\n".join(new) + "\n")
print(" ".join(l.split("=")[0] for l in new))
PY
)
[ -n "$added" ] && warn "new options appended to .env with their defaults: $added"
chmod 600 "$ENV_FILE"
set -a; . "$ENV_FILE"; set +a
CLAUDE_MODEL="${CLAUDE_MODEL:-${DEFAULT_MODEL:-}}"
TARGETS="${TARGETS:-claude codex}"
has_target() { [[ " $TARGETS " == *" $1 "* ]]; }

if [ -d "$OLD_CONFIG_DIR" ]; then
  rm -f "$OLD_CONFIG_DIR/secrets.env"
  rmdir "$OLD_CONFIG_DIR" 2>/dev/null || true
  rm -rf "$HOME/.cache/claude-setup"
  ok "migrated from the old claude-setup config folder"
fi
ok "$SECRETS ($(write_if_changed "$SECRETS" < "$ENV_FILE"))"
chmod 600 "$SECRETS"
LINE='[ -f "$HOME/.config/my-ai-agents/secrets.env" ] && { set -a; . "$HOME/.config/my-ai-agents/secrets.env"; set +a; }'
for rc in "$HOME/.zshrc" "$HOME/.bashrc"; do
  [ -f "$rc" ] || continue
  if grep -qF ".config/claude-setup/secrets.env" "$rc"; then
    sed -i 's#\.config/claude-setup/secrets\.env#.config/my-ai-agents/secrets.env#g; s/^# claude-setup$/# my-ai-agents/' "$rc"
    ok "$(basename "$rc"): updated to the new secrets path"
  fi
  grep -qF "my-ai-agents/secrets.env" "$rc" || { printf '\n# my-ai-agents\n%s\n' "$LINE" >> "$rc"; ok ".env variables exported in $(basename "$rc")"; }
done

step "Your profile"
if [ -f "$PROFILE" ]; then
  ok "$PROFILE (yours, untouched)"
elif [ -f "$CLAUDE_HOME/profile.md" ] && [ ! -L "$CLAUDE_HOME/profile.md" ]; then
  mv "$CLAUDE_HOME/profile.md" "$PROFILE"
  ok "$PROFILE (moved from $CLAUDE_HOME/profile.md)"
else
  cp "$REPO/core/profile.example.md" "$PROFILE"
  warn "$PROFILE created — describe yourself there (who you are, stacks, environment), then run ./install.sh again"
fi

step "Obsidian vault \"Claude Brain\""
if [ -n "${CLAUDE_BRAIN_DIR:-}" ]; then
  VAULT="${CLAUDE_BRAIN_DIR/#\~/$HOME}"
elif grep -qi microsoft /proc/version 2>/dev/null; then
  VAULT="/mnt/c/Claude Brain"
else
  VAULT="$HOME/Claude Brain"
fi
if [ -f "$VAULT/Home.md" ]; then
  ok "$VAULT (existing vault, untouched)"
else
  mkdir -p "$VAULT"/{Projects,Decisions,Sessions,Knowledge,Inbox}
  cp -rn "$REPO/vault/." "$VAULT/"
  ok "$VAULT (new vault created from the skeleton)"
fi
if [ -L "$HOME/claude-brain" ] || [ ! -e "$HOME/claude-brain" ]; then
  ln -sfn "$VAULT" "$HOME/claude-brain"
fi
[ -d "$VAULT/${VAULT_PROJECTS_DIR:-Projects}" ] \
  || warn "projects folder '$VAULT/${VAULT_PROJECTS_DIR:-Projects}' not found — check VAULT_PROJECTS_DIR in .env"
ok "shortcut ~/claude-brain. In Obsidian: Open folder as vault → $VAULT"

step "Rendering core/ for: $TARGETS"
AGENT_MEMORY="$CLAUDE_HOME/agent-memory"
mkdir -p "$AGENT_MEMORY"
chmod +x "$REPO"/core/hooks/* "$REPO/scripts/render.py"
for target in claude codex; do
  has_target "$target" || continue
  PROFILE_FILE="$PROFILE" VAULT_DIR="$VAULT" AGENT_MEMORY_DIR="$AGENT_MEMORY" CODEX_HOME="$CODEX_HOME" \
    "$REPO/scripts/render.py" "$target" "$BUILD/$target"
  ok "build/$target"
done

if has_target claude; then
  step "Claude Code (~/.claude)"
  backup="$CLAUDE_HOME/backups/my-ai-agents-$STAMP"
  link "$BUILD/claude/CLAUDE.md"     "$CLAUDE_HOME/CLAUDE.md"     "$backup"
  link "$BUILD/claude/agents"        "$CLAUDE_HOME/agents"        "$backup"
  link "$REPO/core/hooks"            "$CLAUDE_HOME/hooks"         "$backup"
  link "$REPO/core/skills/commit"    "$CLAUDE_HOME/skills/commit" "$backup"
  if grep -qs "Generated by claude-setup" "$CLAUDE_HOME/preferences.md"; then
    rm "$CLAUDE_HOME/preferences.md"
    ok "removed the old preferences.md (now part of CLAUDE.md)"
  fi
  state=$(CLAUDE_MODEL="$CLAUDE_MODEL" python3 - "$REPO/targets/claude/settings.base.json" "$CLAUDE_HOME/settings.json" <<'PY'
import json, os, pathlib, sys
base = json.load(open(sys.argv[1]))
path = pathlib.Path(sys.argv[2])
cur = json.loads(path.read_text()) if path.exists() else {}
before = json.dumps(cur, sort_keys=True)

def merge(dst, src):
    for k, v in src.items():
        if k == "hooks":
            hooks = dst.setdefault("hooks", {})
            for event, entries in v.items():
                existing = hooks.setdefault(event, [])
                have = {h.get("command") for e in existing for h in e.get("hooks", [])}
                for entry in entries:
                    if not {h.get("command") for h in entry["hooks"]} <= have:
                        existing.append(entry)
        elif isinstance(v, dict) and isinstance(dst.get(k), dict):
            merge(dst[k], v)
        else:
            dst[k] = v

merge(cur, base)

if os.environ.get("DB_GUARD", "on").lower() == "off":
    pre = cur.get("hooks", {}).get("PreToolUse", [])
    for e in pre:
        e["hooks"] = [h for h in e.get("hooks", []) if "db-guard" not in h.get("command", "")]
    cur["hooks"]["PreToolUse"] = [e for e in pre if e["hooks"]]
    if not cur["hooks"]["PreToolUse"]:
        del cur["hooks"]["PreToolUse"]

if os.environ.get("CLAUDE_MODEL"):
    cur["model"] = os.environ["CLAUDE_MODEL"]
if os.environ.get("RESPONSE_LANGUAGE"):
    cur["language"] = os.environ["RESPONSE_LANGUAGE"]

if json.dumps(cur, sort_keys=True) != before:
    path.write_text(json.dumps(cur, indent=2, ensure_ascii=False) + "\n")
    print("changed")
else:
    print("unchanged")
PY
  )
  ok "$CLAUDE_HOME/settings.json ($state)"
fi

# Edits $CODEX_HOME/config.toml without a TOML library: top-level keys and whole [sections].
#   codex_config set-key <key> <toml-value>
#   codex_config has <section>
#   codex_config put <section> <body>      (replaces the section and its subtables)
#   codex_config add-roots <path>...        (adds paths to [sandbox_workspace_write] writable_roots)
codex_config() {
  python3 - "$CODEX_HOME/config.toml" "$@" <<'PY'
import pathlib, re, sys
path, cmd, args = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3:]
lines = path.read_text().splitlines() if path.exists() else []
header = lambda l: re.match(r"\s*\[\[?\s*([^\]]+?)\s*\]\]?\s*(#.*)?$", l)

def section_range(name):
    start = next((i for i, l in enumerate(lines) if (m := header(l)) and m.group(1) == name), None)
    if start is None:
        return None
    end = start + 1
    while end < len(lines) and not ((m := header(lines[end])) and not m.group(1).startswith(name + ".")):
        end += 1
    return start, end

if cmd == "has":
    sys.exit(0 if section_range(args[0]) else 1)

if cmd == "set-key":
    key, value = args
    first = next((i for i, l in enumerate(lines) if header(l)), len(lines))
    new = f"{key} = {value}"
    idx = next((i for i in range(first) if re.match(rf"\s*{re.escape(key)}\s*=", lines[i])), None)
    if idx is not None:
        if lines[idx].strip() == new:
            print("unchanged"); sys.exit()
        lines[idx] = new
    else:
        lines.insert(0, new)
elif cmd == "add-roots":
    import json
    rng = section_range("sandbox_workspace_write")
    if not rng:
        lines += ["", "[sandbox_workspace_write]", f"writable_roots = {json.dumps(args)}"]
    else:
        idx = next((i for i in range(*rng) if re.match(r"\s*writable_roots\s*=", lines[i])), None)
        if idx is None:
            lines.insert(rng[0] + 1, f"writable_roots = {json.dumps(args)}")
        else:
            try:
                roots = json.loads(lines[idx].split("=", 1)[1])
            except ValueError:
                print("manual"); sys.exit()
            missing = [a for a in args if a not in roots]
            if not missing:
                print("unchanged"); sys.exit()
            lines[idx] = f"writable_roots = {json.dumps(roots + missing)}"
elif cmd == "put":
    name, body = args
    block = [f"[{name}]"] + body.splitlines()
    rng = section_range(name)
    if rng and lines[rng[0]:rng[1]] and [l for l in lines[rng[0]:rng[1]] if l.strip()] == block:
        print("unchanged"); sys.exit()
    if rng:
        del lines[rng[0]:rng[1]]
    while lines and not lines[-1].strip():
        lines.pop()
    lines += ([""] if lines else []) + block
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text("\n".join(lines) + "\n")
path.chmod(0o600)
print("changed")
PY
}

CODEX_BIN="$(command -v codex 2>/dev/null || ls -d "$HOME"/.vscode-server/extensions/openai.chatgpt-*/bin/*/codex 2>/dev/null | sort -V | tail -1 || true)"
if has_target codex; then
  step "Codex (~/.codex)"
  backup="$CODEX_HOME/backups/my-ai-agents-$STAMP"
  link "$BUILD/codex/AGENTS.md"      "$CODEX_HOME/AGENTS.md"      "$backup"
  link "$BUILD/codex/agents"         "$CODEX_HOME/agents"         "$backup"
  link "$REPO/core/hooks"            "$CODEX_HOME/hooks"          "$backup"
  link "$BUILD/codex/hooks.json"     "$CODEX_HOME/hooks.json"     "$backup"
  link "$REPO/core/skills/commit"    "$HOME/.agents/skills/commit" "$backup"
  if [ -n "${CODEX_MODEL:-}" ]; then
    ok "config.toml model = $CODEX_MODEL ($(codex_config set-key model "\"$CODEX_MODEL\""))"
  fi
  state=$(codex_config add-roots "$VAULT" "$AGENT_MEMORY")
  [ "$state" = manual ] && warn "add \"$VAULT\" and \"$AGENT_MEMORY\" to [sandbox_workspace_write] writable_roots in config.toml by hand" \
    || ok "config.toml writable_roots: vault + shared agent memory ($state)"
  warn "Codex asks you to trust hooks: run /hooks inside Codex once (and again after hooks.json changes)"
  [ -n "$CODEX_BIN" ] && ok "codex: $("$CODEX_BIN" --version 2>/dev/null | head -1)" \
    || warn "Codex CLI not found (npm i -g @openai/codex). Files are in place; MCP logins need the CLI."
fi

if [ "$OFFLINE" = 1 ]; then
  step "Skipping MCP servers, skills and plugins (--offline)"
else
  HAS_CLAUDE=0
  if has_target claude; then
    command -v claude >/dev/null && HAS_CLAUDE=1 \
      || warn "Claude Code not found (npm i -g @anthropic-ai/claude-code). Its MCP servers and plugins will be skipped."
  fi

  if [ "$HAS_CLAUDE" = 1 ]; then
    step "Claude Code MCP servers (user scope)"
    # Prints a header of MCP server $1 from ~/.claude.json (if $2 is given); exits 1 if the server doesn't exist.
    mcp_field() {
      python3 - "$@" <<'PY'
import json, pathlib, sys
p = pathlib.Path.home() / ".claude.json"
servers = json.loads(p.read_text()).get("mcpServers", {}) if p.exists() else {}
s = servers.get(sys.argv[1])
if s is None:
    sys.exit(1)
if len(sys.argv) > 2:
    print((s.get("headers") or {}).get(sys.argv[2], ""))
PY
    }
    add_mcp() {
      local name="$1"; shift
      if mcp_field "$name" >/dev/null; then ok "$name (already configured)"
      else claude mcp add --scope user "$name" "$@" >/dev/null && ok "$name"; fi
    }
    add_mcp context7 --transport http https://mcp.context7.com/mcp
    add_mcp playwright -- npx @playwright/mcp@latest
    add_mcp atlassian --transport http https://mcp.atlassian.com/v2/mcp
    if [ -n "${GITHUB_PAT:-}" ]; then
      current="$(mcp_field github Authorization 2>/dev/null || true)"
      if [ "$current" = "Bearer $GITHUB_PAT" ]; then
        ok "github (already configured)"
      else
        [ -n "$current" ] && claude mcp remove --scope user github >/dev/null 2>&1 || true
        claude mcp add --scope user --transport http github https://api.githubcopilot.com/mcp \
          --header "Authorization: Bearer $GITHUB_PAT" >/dev/null && ok "github (token updated from .env)"
      fi
    elif mcp_field github >/dev/null; then
      ok "github (already configured; GITHUB_PAT is empty in .env, kept the current token)"
    else
      warn "github: set GITHUB_PAT in .env and run again"
    fi
    warn "Atlassian uses OAuth: run /mcp inside Claude Code to log in, if you haven't yet"
  fi

  if has_target codex; then
    step "Codex MCP servers (~/.codex/config.toml)"
    add_codex_mcp() {
      local name="$1" body="$2"
      if codex_config has "mcp_servers.$name"; then ok "$name (already configured)"
      else codex_config put "mcp_servers.$name" "$body" >/dev/null && ok "$name"; fi
    }
    add_codex_mcp context7  'url = "https://mcp.context7.com/mcp"'
    add_codex_mcp playwright $'command = "npx"\nargs = ["@playwright/mcp@latest"]'
    add_codex_mcp atlassian 'url = "https://mcp.atlassian.com/v2/mcp"'
    if [ -n "${GITHUB_PAT:-}" ]; then
      state=$(codex_config put mcp_servers.github \
        $'url = "https://api.githubcopilot.com/mcp"\nhttp_headers = { Authorization = "Bearer '"$GITHUB_PAT"$'" }')
      [ "$state" = changed ] && ok "github (token updated from .env)" || ok "github (already configured)"
    elif codex_config has mcp_servers.github; then
      ok "github (already configured; GITHUB_PAT is empty in .env, kept the current token)"
    else
      warn "github: set GITHUB_PAT in .env and run again"
    fi
    warn "Atlassian uses OAuth: run '${CODEX_BIN:-codex} mcp login atlassian' once, if you haven't yet"
  fi

  step "Third-party skills"
  skill_agents=()
  has_target claude && skill_agents+=(-a claude-code)
  has_target codex && skill_agents+=(-a codex)
  install_skills() {
    local check="$1"; shift
    if { has_target claude && [ ! -e "$CLAUDE_HOME/skills/$check" ]; } || { has_target codex && [ ! -e "$HOME/.agents/skills/$check" ]; }; then
      npx -y skills add "$@" -g "${skill_agents[@]}" -y
    else
      ok "$check (already installed)"
    fi
  }
  install_skills supabase supabase/agent-skills -s supabase -s supabase-postgres-best-practices
  install_skills find-skills vercel-labs/skills -s find-skills

  step "Official Jev skill (TypeSafe)"
  if [ "$HAS_CLAUDE" = 1 ]; then
    if claude plugin list 2>/dev/null | grep -q "typesafe@typesafe-ai"; then ok "claude: typesafe plugin (already installed)"
    else
      claude plugin marketplace add typesafe-ai/skills >/dev/null 2>&1 || true
      claude plugin install typesafe@typesafe-ai >/dev/null && ok "claude: typesafe@typesafe-ai"
    fi
  fi
  if has_target codex; then
    [ -e "$HOME/.agents/skills/typesafe-ai" ] && ok "codex: typesafe-ai (already installed)" \
      || npx -y skills add typesafe-ai/skills -g -a codex -s typesafe-ai -y
  fi
fi

step "Done"
[ -n "${TYPESAFE_API_KEY:-}" ] && ok "Jev: key configured" || warn "Jev: TYPESAFE_API_KEY is empty in .env (the database guard uses regex only)"
[ "${DB_GUARD:-on}" = "off" ] && warn "DB_GUARD=off — database guard disabled"
echo "  Restart Claude Code / Codex to load changes to rules, agents, hooks and settings."
