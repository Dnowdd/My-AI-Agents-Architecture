#!/usr/bin/env python3
"""PreToolUse(Bash) hook: database commands outside a local test database need the user's approval.

1. Cheap regex prefilter — most commands never mention a database and exit right away.
2. Resolve the target database: URLs/--host in the command, else DATABASE_URL/DIRECT_URL/
   SHADOW_DATABASE_URL from the project's .env files.
3. Jev decides whether the command really connects to a database (prisma generate, cat schema,
   npm i prisma… don't). Without Jev, a strict regex of connecting commands decides.
4. Local target (localhost, docker service, sqlite) → free. Remote or unknown target → ask.
   When Jev tokens expired, tell the user once per session and skip Jev.

With --codex: Codex hooks cannot "ask" yet, so a remote target is denied with instructions to get
the user's approval in chat and re-run the command prefixed with APPROVAL_PREFIX.
"""
import json
import pathlib
import re
import subprocess
import sys
from urllib.parse import urlparse

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from jev import JevUnavailable, ask  # noqa: E402

THRESHOLD = 0.5
LOCAL_HOSTS = {"localhost", "127.0.0.1", "::1", "0.0.0.0", "host.docker.internal"}
URL_VARS = ("DATABASE_URL", "DIRECT_URL", "SHADOW_DATABASE_URL", "POSTGRES_URL", "MYSQL_URL")

MENTIONS_DB = re.compile(
    r"\b(prisma|psql|mysql|mariadb|supabase|sqlite3?|pg_restore|pg_dump|mongosh|knex|typeorm|"
    r"sequelize|drizzle-kit|migrat\w*|seed\w*|db:\w+|redis-cli)\b"
    r"|\b(select\s.+\sfrom|insert\s+into|update\s+\w+\s+set|delete\s+from|drop\s+(table|database|schema)|truncate|alter\s+table)\b"
    r"|\b(postgres(ql)?|mysql|mariadb|mongodb(\+srv)?|redis)://",
    re.I,
)
CONNECTS = re.compile(
    r"\bprisma\s+(migrate\s+(deploy|dev|reset|resolve|status|diff)|db\s+(push|pull|execute|seed)|studio)"
    r"|\b(psql|mysql|mariadb|mongosh|redis-cli|sqlite3|pg_restore|pg_dump)\b"
    r"|\bsupabase\s+(db|migration)\s+\w+"
    r"|\b(npm|pnpm|yarn|bun)\s+(run\s+)?(db:|migrat|seed)\S*"
    r"|\b(knex|sequelize)\s+(migrate|seed|db:)\S*|\btypeorm\b.*\bmigration:(run|revert)|\bdrizzle-kit\s+(push|migrate)",
    re.I,
)
URL_RE = re.compile(r"\b(?:postgres(?:ql)?|mysql|mariadb|mongodb(?:\+srv)?|redis|file|sqlite)[:][^\s'\"]+", re.I)
HOST_FLAG_RE = re.compile(r"(?:^|\s)(?:-h\s*|--host[=\s]+)([\w.\-:]+)")

QUESTION = {
    "type": "noul",
    "instructions": "Does running `command` connect to or operate on a database "
                    "(query it, migrate, push a schema, seed, reset, restore, or open a DB shell or studio)?",
    "criteria": {
        "true": "It opens a connection to some database.",
        "false": "It only reads or edits local files, installs packages, generates code "
                 "(prisma generate/format/validate), or merely mentions a database.",
    },
}

FLAG_DIR = pathlib.Path.home() / ".cache/my-ai-agents"
CODEX = "--codex" in sys.argv[1:]
APPROVAL_PREFIX = "DB_GUARD_APPROVED=1 "


def env_urls(cwd):
    dirs = [pathlib.Path(cwd)] if cwd else []
    try:
        root = subprocess.run(["git", "-C", cwd or ".", "rev-parse", "--show-toplevel"],
                              capture_output=True, text=True, timeout=2).stdout.strip()
        if root:
            dirs.append(pathlib.Path(root))
    except (OSError, subprocess.SubprocessError):
        pass
    urls = []
    for d in dict.fromkeys(dirs):
        for name in (".env", ".env.local", ".env.development", "prisma/.env"):
            f = d / name
            if not f.is_file():
                continue
            for line in f.read_text(errors="replace").splitlines():
                m = re.match(r"\s*(?:export\s+)?(\w+)\s*=\s*(.*)", line)
                if m and m.group(1) in URL_VARS and m.group(2).strip():
                    urls.append(m.group(2).strip().strip("'\""))
    return urls


def host_of(url):
    if url.lower().startswith(("file:", "sqlite:")):
        return "sqlite"
    try:
        return (urlparse(url).hostname or "").lower()
    except ValueError:
        return ""


def is_local(host):
    # sqlite files and docker-compose service names (no dot, e.g. "db", "postgres") are local
    return host in LOCAL_HOSTS or host == "sqlite" or bool(re.fullmatch(r"[a-z][\w-]*", host))


def resolve_target(command, cwd):
    """Returns (kind, hosts) with kind in local | remote | unknown."""
    hosts = [host_of(u) for u in URL_RE.findall(command)]
    hosts += [h.lower() for h in HOST_FLAG_RE.findall(command)]
    if re.search(r"\bsupabase\b", command, re.I):
        if re.search(r"--linked|--db-url|\bdb\s+push\b(?!.*--local)", command):
            hosts.append("supabase (linked project)")
        elif not hosts:
            hosts.append("localhost")
    if re.search(r"\bsqlite3\b", command) and not hosts:
        hosts.append("sqlite")
    if not hosts:
        hosts = [host_of(u) for u in env_urls(cwd)]
    hosts = [h for h in dict.fromkeys(hosts) if h]
    if not hosts:
        return "unknown", []
    return ("local" if all(is_local(h) for h in hosts) else "remote"), hosts


def emit(decision=None, reason="", system_message="", context=""):
    out = {}
    specific = {"hookEventName": "PreToolUse"}
    if decision:
        specific["permissionDecision"] = decision
        specific["permissionDecisionReason"] = reason
    if context:
        specific["additionalContext"] = context
    if len(specific) > 1:
        out["hookSpecificOutput"] = specific
    if system_message:
        out["systemMessage"] = system_message
    if out:
        print(json.dumps(out, ensure_ascii=False))


def warn_expired_once(session_id):
    flag = FLAG_DIR / f"jev-warned-{session_id or 'nosession'}"
    if flag.exists():
        return "", ""
    FLAG_DIR.mkdir(parents=True, exist_ok=True)
    flag.touch()
    return (
        "⚠️ Jev tokens expired — skipping Jev (database guard running in regex mode).",
        "The Jev decision model is unavailable because its tokens expired. Tell the user in ONE short line "
        "of your reply, in their language, that their Jev tokens expired. Do not retry Jev this session.",
    )


def main():
    try:
        payload = json.load(sys.stdin)
    except ValueError:
        return
    command = (payload.get("tool_input") or {}).get("command", "")
    if isinstance(command, list):
        command = " ".join(command)
    if not command or not MENTIONS_DB.search(command):
        return
    if CODEX and command.lstrip().startswith(APPROVAL_PREFIX):
        return
    cwd = payload.get("cwd", "")

    system_message, context = "", ""
    try:
        answers = ask({"command": command, "cwd": cwd}, {"touches_db": QUESTION}, timeout=4)
        touches = answers["touches_db"]["noul"] >= THRESHOLD
    except (JevUnavailable, KeyError, TypeError) as e:
        if isinstance(e, JevUnavailable) and e.reason == "expired":
            system_message, context = warn_expired_once(payload.get("session_id", ""))
        touches = bool(CONNECTS.search(command))

    if not touches:
        emit(system_message=system_message, context=context)
        return

    kind, hosts = resolve_target(command, cwd)
    if kind == "local":
        emit(system_message=system_message, context=context)
        return
    label = f"REMOTE database ({', '.join(hosts)})" if kind == "remote" else "Unknown target database"
    if CODEX:
        emit("deny",
             f"{label}. Blocked: only local test databases are free. Do not retry yet. Ask the user for approval, "
             f"showing the target and the exact command. Only after the user explicitly approves in this "
             f"conversation, re-run the exact same command prefixed with `{APPROVAL_PREFIX.strip()}`.",
             system_message, context)
        return
    emit("ask",
         f"{label}. Only local test databases are free: explain what you will do and show the exact command first.",
         system_message, context)


if __name__ == "__main__":
    main()
