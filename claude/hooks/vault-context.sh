#!/usr/bin/env bash
# SessionStart: injects the current repo's project note from the "Claude Brain" vault.
VAULT="$HOME/claude-brain"
SECRETS="$HOME/.config/claude-setup/secrets.env"
[ -f "$SECRETS" ] && { set -a; . "$SECRETS" 2>/dev/null; set +a; }
PROJECTS="$VAULT/${VAULT_PROJECTS_DIR:-Projects}"
[ -d "$PROJECTS" ] || exit 0

cwd=$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("cwd",""))' 2>/dev/null)
[ -n "$cwd" ] || cwd=$PWD
root=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null) || exit 0
name=$(basename "$root")
note="$PROJECTS/$name.md"

if [ -f "$note" ]; then
  echo "## Project context from the Claude Brain vault — $note"
  head -n 150 "$note"
  echo
  echo "(Full note: $note. Vault conventions: $VAULT/Home.md.)"
else
  echo "Claude Brain vault: no project note for '$name' yet ($note). After meaningful work, ask the scribe agent to create it."
fi
