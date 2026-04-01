#!/usr/bin/env python3

import argparse
import json
import re
import sys
from pathlib import Path


CLAUDE_MARKER = "silent-casting-managed:claude"
CODEX_MARKER = "silent-casting-managed:codex"
LEGACY_CLAUDE_MARKER = "skills-sync-managed:claude"
LEGACY_CODEX_MARKER = "skills-sync-managed:codex"


def read_json(path: Path) -> dict:
    if not path.exists():
        return {}
    try:
        return json.loads(path.read_text())
    except json.JSONDecodeError as exc:
        raise SystemExit(f"Invalid JSON in {path}: {exc}") from exc


def write_json(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2) + "\n")


def remove_managed_hooks(entries: list, markers: list[str]) -> list:
    filtered = []
    for entry in entries:
        hooks = entry.get("hooks", [])
        kept_hooks = [
            hook
            for hook in hooks
            if not any(marker in str(hook.get("command", "")) for marker in markers)
        ]
        if kept_hooks:
            new_entry = dict(entry)
            new_entry["hooks"] = kept_hooks
            filtered.append(new_entry)
    return filtered


def upsert_session_start_hook(
    path: Path, command: str, marker: str, legacy_markers: list[str] | None = None
) -> None:
    config = read_json(path)
    hooks = config.setdefault("hooks", {})
    session_start = hooks.setdefault("SessionStart", [])
    markers = [marker]
    if legacy_markers:
        markers.extend(legacy_markers)
    hooks["SessionStart"] = remove_managed_hooks(session_start, markers)
    hooks["SessionStart"].append(
        {
            "matcher": "startup|resume",
            "hooks": [
                {
                    "type": "command",
                    "command": command,
                }
            ],
        }
    )
    write_json(path, config)


def enable_codex_hooks(config_path: Path) -> None:
    config_path.parent.mkdir(parents=True, exist_ok=True)
    text = config_path.read_text() if config_path.exists() else ""

    dotted_pattern = re.compile(r"(?m)^(\s*features\.codex_hooks\s*=\s*).*$")
    if dotted_pattern.search(text):
        config_path.write_text(dotted_pattern.sub(r"\1true", text))
        return

    feature_table_pattern = re.compile(r"(?m)^\[features\]\s*$")
    match = feature_table_pattern.search(text)
    if match:
        section_start = match.end()
        section_tail = text[section_start:]
        next_table = re.search(r"(?m)^\[.*\]\s*$", section_tail)
        insert_at = len(text) if next_table is None else section_start + next_table.start()
        section_body = text[section_start:insert_at]
        table_key_pattern = re.compile(r"(?m)^(\s*codex_hooks\s*=\s*).*$")
        if table_key_pattern.search(section_body):
            updated_section = table_key_pattern.sub(r"\1true", section_body)
            updated = text[:section_start] + updated_section + text[insert_at:]
        else:
            insertion = "\ncodex_hooks = true"
            updated = text[:insert_at] + insertion + text[insert_at:]
        if not updated.endswith("\n"):
            updated += "\n"
        config_path.write_text(updated)
        return

    pieces = []
    if text.strip():
        pieces.append(text.rstrip())
    pieces.append("[features]\ncodex_hooks = true")
    config_path.write_text("\n\n".join(pieces) + "\n")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--target", choices=["claude", "codex", "all"], required=True)
    parser.add_argument("--claude-command")
    parser.add_argument("--codex-command")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    home = Path.home()

    if args.target in {"claude", "all"}:
        if not args.claude_command:
            raise SystemExit("--claude-command is required for Claude bootstrap")
        upsert_session_start_hook(
            home / ".claude" / "settings.json",
            args.claude_command,
            CLAUDE_MARKER,
            [LEGACY_CLAUDE_MARKER],
        )

    if args.target in {"codex", "all"}:
        if not args.codex_command:
            raise SystemExit("--codex-command is required for Codex bootstrap")
        enable_codex_hooks(home / ".codex" / "config.toml")
        upsert_session_start_hook(
            home / ".codex" / "hooks.json",
            args.codex_command,
            CODEX_MARKER,
            [LEGACY_CODEX_MARKER],
        )

    return 0


if __name__ == "__main__":
    sys.exit(main())
