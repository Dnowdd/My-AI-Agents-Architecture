#!/usr/bin/env python3
"""Minimal TypeSafe Jev client (stdlib only) — used by hooks and callable as a CLI.

CLI:
  jev.py noul   "question"                     < state
  jev.py choice "question" '{"a": "...", ...}' < state
  jev.py score  "question" '["low", "high"]'   < state
Prints the answer as JSON. Exit 3 with "JEV_UNAVAILABLE:<reason>" on stderr when Jev
cannot be used (reason: no_key | expired | transient).
"""
import json
import os
import pathlib
import sys
import time
import urllib.error
import urllib.request

API_URL = "https://api.typesafe.ai/v1/systemone"
SECRETS = pathlib.Path.home() / ".config/claude-setup/secrets.env"
EXPIRED_FLAG = pathlib.Path.home() / ".cache/claude-setup/jev-expired"
EXPIRED_TTL = 15 * 60  # after a 401/402/403, don't hit the API again for 15 min


class JevUnavailable(Exception):
    def __init__(self, reason, detail=""):
        super().__init__(f"{reason}: {detail}" if detail else reason)
        self.reason = reason


def setting(name, default=""):
    """Env var first, then the secrets file synced from claude-setup/.env."""
    value = os.environ.get(name, "").strip()
    if value or not SECRETS.exists():
        return value or default
    for line in SECRETS.read_text().splitlines():
        line = line.strip().removeprefix("export ").strip()
        if line.startswith(f"{name}="):
            return line.split("=", 1)[1].split(" #")[0].strip().strip("'\"") or default
    return default


def ask(state, questions, timeout=5):
    key = setting("TYPESAFE_API_KEY")
    if not key:
        raise JevUnavailable("no_key")
    if EXPIRED_FLAG.exists() and time.time() - EXPIRED_FLAG.stat().st_mtime < EXPIRED_TTL:
        raise JevUnavailable("expired", "cached")

    body = json.dumps({"model": setting("JEV_MODEL", "jev-latest"), "state": state, "questions": questions}).encode()
    req = urllib.request.Request(
        API_URL,
        data=body,
        headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            data = json.load(resp)
    except urllib.error.HTTPError as e:
        detail = e.read().decode(errors="replace")[:300]
        if e.code in (401, 402, 403):
            EXPIRED_FLAG.parent.mkdir(parents=True, exist_ok=True)
            EXPIRED_FLAG.write_text(f"{e.code} {detail}")
            raise JevUnavailable("expired", f"HTTP {e.code}")
        raise JevUnavailable("transient", f"HTTP {e.code} {detail}")
    except (urllib.error.URLError, TimeoutError, OSError) as e:
        raise JevUnavailable("transient", str(e))

    EXPIRED_FLAG.unlink(missing_ok=True)
    return data["answers"]


def main(argv):
    if len(argv) < 3 or argv[1] not in ("noul", "choice", "score"):
        print(__doc__, file=sys.stderr)
        return 2
    kind, instructions = argv[1], argv[2]
    question = {"type": kind, "instructions": instructions}
    if kind in ("choice", "score"):
        if len(argv) < 4:
            print(f"{kind} needs criteria as JSON", file=sys.stderr)
            return 2
        question["criteria"] = json.loads(argv[3])
    state = sys.stdin.read() if not sys.stdin.isatty() else ""
    try:
        answer = ask(state or "(empty)", {"q": question})["q"]
    except JevUnavailable as e:
        print(f"JEV_UNAVAILABLE:{e.reason}", file=sys.stderr)
        return 3
    print(json.dumps(answer, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
