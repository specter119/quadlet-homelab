#!/usr/bin/env python3
"""Follow the user journal and send a desktop notification when a rule matches.

Rules live in ~/.config/log-notify/rules.d/*.toml, one file per service:

    [[rule]]
    unit    = "multica-server.service"      # required: only this unit's lines are scanned
    pattern = 'code for (?P<who>\\S+): (?P<code>\\d+)'
    title   = "Multica"
    body    = "{code} ({who})"              # str.format with the named groups
"""

import json
import os
import re
import shutil
import subprocess
import sys
import tomllib
from pathlib import Path

RULES_DIR = Path(
    os.environ.get("LOG_NOTIFY_RULES_DIR", "~/.config/log-notify/rules.d")
).expanduser()
NOTIFY_SH = Path(
    os.environ.get("LOG_NOTIFY_SH", "~/.local/share/cli-hooks/notify.sh")
).expanduser()


def log(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


def load_rules() -> dict[str, list[dict]]:
    by_unit: dict[str, list[dict]] = {}
    for path in sorted(RULES_DIR.glob("*.toml")):
        try:
            data = tomllib.loads(path.read_text(encoding="utf-8"))
        except (OSError, tomllib.TOMLDecodeError) as exc:
            log(f"skip {path.name}: {exc}")
            continue
        for i, raw in enumerate(data.get("rule", [])):
            try:
                rule = {
                    "name": f"{path.stem}#{i}",
                    "re": re.compile(raw["pattern"]),
                    "title": raw.get("title", path.stem),
                    "body": raw.get("body", "{0}"),
                }
                by_unit.setdefault(raw["unit"], []).append(rule)
            except (KeyError, re.error) as exc:
                log(f"skip rule {path.name}#{i}: {exc!r}")
    return by_unit


def notify(title: str, body: str) -> None:
    # notify.sh (dotfiles) handles WSL toast vs. Linux notify-send.
    if NOTIFY_SH.exists():
        # Run via bash: the dotfiles symlink target is not marked executable.
        cmd, env = (
            ["bash", str(NOTIFY_SH), body],
            {**os.environ, "NOTIFICATION_TITLE": title},
        )
    elif shutil.which("notify-send"):
        cmd, env = ["notify-send", title, body], os.environ
    else:
        log("no notifier available (notify.sh / notify-send)")
        return
    try:
        subprocess.run(cmd, env=env, timeout=20, check=False, stdout=subprocess.DEVNULL)
    except (OSError, subprocess.TimeoutExpired) as exc:
        log(f"notify failed: {exc!r}")


def main() -> int:
    rules = load_rules()
    if not rules:
        log(f"no rules in {RULES_DIR}, exiting")
        return 0

    cmd = ["journalctl", "--user", "-f", "-n", "0", "-o", "json"]
    for unit in rules:
        cmd += ["-u", unit]
    log(f"watching {len(sum(rules.values(), []))} rule(s) on {len(rules)} unit(s)")

    with subprocess.Popen(
        cmd, stdout=subprocess.PIPE, text=True, errors="replace"
    ) as proc:
        for line in proc.stdout:
            try:
                entry = json.loads(line)
            except json.JSONDecodeError:
                continue
            message = entry.get("MESSAGE")
            if not isinstance(message, str):
                continue
            for rule in rules.get(entry.get("_SYSTEMD_USER_UNIT", ""), ()):
                m = rule["re"].search(message)
                if not m:
                    continue
                # Never log the matched text: it may be a one-time secret.
                log(f"rule {rule['name']} matched")
                notify(rule["title"], rule["body"].format(m.group(0), **m.groupdict()))
    return proc.returncode or 1


if __name__ == "__main__":
    sys.exit(main())
