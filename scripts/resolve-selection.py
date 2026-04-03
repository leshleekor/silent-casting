#!/usr/bin/env python3

import argparse
import fnmatch
import hashlib
import json
import os
import shlex
import sys
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--skills-root", required=True)
    parser.add_argument("--profiles-file")
    parser.add_argument("--selection-file", required=True)
    parser.add_argument("--selection-file-required", action="store_true")
    parser.add_argument("--output-env", required=True)
    parser.add_argument("--output-list", required=True)
    parser.add_argument("--profile", action="append", default=[])
    parser.add_argument("--include", action="append", default=[])
    parser.add_argument("--exclude", action="append", default=[])
    return parser.parse_args()


def parse_env_list(name: str) -> tuple[bool, list[str]]:
    if name not in os.environ:
        return False, []
    value = os.environ.get(name, "")
    items = [item.strip() for item in value.split(",") if item.strip()]
    return True, items


def load_json(path: Path, required: bool) -> dict | None:
    if not path.exists():
        if required:
            raise SystemExit(f"required file not found: {path}")
        return None
    try:
        data = json.loads(path.read_text())
    except json.JSONDecodeError as exc:
        raise SystemExit(f"invalid JSON in {path}: {exc}") from exc
    if not isinstance(data, dict):
        raise SystemExit(f"top-level JSON value must be an object: {path}")
    return data


def read_string_list(
    data: dict, key: str, source_name: str, default: list[str] | None = None
) -> list[str]:
    if key not in data:
        return [] if default is None else list(default)
    value = data[key]
    if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
        raise SystemExit(f"{source_name}.{key} must be a list of strings")
    return [item.strip() for item in value if item.strip()]


def list_skill_ids(skills_root: Path) -> list[str]:
    skill_ids = []
    for skill_md in sorted(skills_root.glob("**/SKILL.md")):
        skill_dir = skill_md.parent
        rel_dir = skill_dir.relative_to(skills_root).as_posix()
        skill_ids.append(rel_dir)
    return skill_ids


def resolve_matches(entries: list[str], skill_ids: list[str], label: str) -> set[str]:
    selected: set[str] = set()
    for entry in entries:
        if "*" in entry:
            matches = [skill_id for skill_id in skill_ids if fnmatch.fnmatchcase(skill_id, entry)]
        else:
            matches = [skill_id for skill_id in skill_ids if skill_id == entry]
        if not matches:
            raise SystemExit(f"{label} entry did not match any skill: {entry}")
        selected.update(matches)
    return selected


def join_list(items: list[str]) -> str:
    return ",".join(items)


def write_shell_env(path: Path, values: dict[str, str]) -> None:
    lines = [f"{key}={shlex.quote(value)}" for key, value in values.items()]
    path.write_text("\n".join(lines) + "\n")


def write_skill_list(path: Path, skill_ids: list[str]) -> None:
    path.write_text("\n".join(skill_ids) + ("\n" if skill_ids else ""))


def selection_hash(
    mode: str,
    profiles: list[str],
    include: list[str],
    exclude: list[str],
    mandatory: list[str],
    selection_file: str,
) -> str:
    payload = {
        "mode": mode,
        "profiles": profiles,
        "include": include,
        "exclude": exclude,
        "mandatory": mandatory,
        "selection_file": selection_file,
    }
    encoded = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(encoded).hexdigest()


def main() -> int:
    args = parse_args()

    skills_root = Path(args.skills_root).resolve()
    profiles_file = Path(args.profiles_file).resolve() if args.profiles_file else None
    selection_file = Path(args.selection_file).resolve()
    output_env = Path(args.output_env).resolve()
    output_list = Path(args.output_list).resolve()

    if not skills_root.is_dir():
        raise SystemExit(f"skills directory not found: {skills_root}")

    skill_ids = list_skill_ids(skills_root)
    if not skill_ids:
        raise SystemExit(f"no SKILL.md files found under {skills_root}")

    explicit_env_profiles, env_profiles = parse_env_list("SKILLS_PROFILE")
    explicit_env_include, env_include = parse_env_list("SKILLS_INCLUDE")
    explicit_env_exclude, env_exclude = parse_env_list("SKILLS_EXCLUDE")

    selection_data = load_json(selection_file, required=args.selection_file_required)
    selection_file_value = str(selection_file) if selection_data is not None else ""

    if profiles_file is None or not profiles_file.exists():
        ignored_selection = (
            bool(args.profile)
            or bool(args.include)
            or bool(args.exclude)
            or explicit_env_profiles
            or explicit_env_include
            or explicit_env_exclude
            or selection_data is not None
        )
        if ignored_selection:
            print(
                "[silent-casting] profiles.json not found; selection settings are ignored and full sync will be used",
                file=sys.stderr,
            )

        selected_skills = sorted(skill_ids)
        mode = "all"
        write_skill_list(output_list, selected_skills)
        write_shell_env(
            output_env,
            {
                "RESOLVED_SYNC_MODE": mode,
                "RESOLVED_PROFILES": "",
                "RESOLVED_INCLUDE": "",
                "RESOLVED_EXCLUDE": "",
                "RESOLVED_MANDATORY": "",
                "RESOLVED_SELECTION_FILE": selection_file_value,
                "RESOLVED_SELECTION_HASH": selection_hash(
                    mode, [], [], [], [], selection_file_value
                ),
                "RESOLVED_SKILL_COUNT": str(len(selected_skills)),
            },
        )
        return 0

    profiles_data = load_json(profiles_file, required=True)

    if "version" in profiles_data and not isinstance(profiles_data["version"], int):
        raise SystemExit("profiles.json.version must be an integer")

    mandatory = read_string_list(profiles_data, "mandatory", "profiles.json")
    default_profiles = read_string_list(profiles_data, "default_profiles", "profiles.json")

    profiles_obj = profiles_data.get("profiles", {})
    if not isinstance(profiles_obj, dict):
        raise SystemExit("profiles.json.profiles must be an object")

    normalized_profiles: dict[str, dict[str, list[str] | str]] = {}
    for name, raw_value in profiles_obj.items():
        if not isinstance(name, str):
            raise SystemExit("profiles.json profile names must be strings")
        if not isinstance(raw_value, dict):
            raise SystemExit(f"profiles.json.profiles.{name} must be an object")
        description = raw_value.get("description", "")
        if description is not None and not isinstance(description, str):
            raise SystemExit(f"profiles.json.profiles.{name}.description must be a string")
        normalized_profiles[name] = {
            "description": description or "",
            "include": read_string_list(raw_value, "include", f"profiles.json.profiles.{name}"),
            "exclude": read_string_list(raw_value, "exclude", f"profiles.json.profiles.{name}"),
        }

    selection_present = selection_data is not None
    selection_profiles = (
        read_string_list(selection_data, "profiles", "selection.json")
        if selection_present
        else []
    )
    selection_include = (
        read_string_list(selection_data, "include", "selection.json")
        if selection_present
        else []
    )
    selection_exclude = (
        read_string_list(selection_data, "exclude", "selection.json")
        if selection_present
        else []
    )
    if selection_present and "version" in selection_data and not isinstance(
        selection_data["version"], int
    ):
        raise SystemExit("selection.json.version must be an integer")

    if args.profile:
        active_profiles = list(dict.fromkeys(args.profile))
    elif explicit_env_profiles:
        active_profiles = list(dict.fromkeys(env_profiles))
    elif selection_present:
        active_profiles = selection_profiles
    else:
        active_profiles = default_profiles

    if args.include:
        user_include = list(dict.fromkeys(args.include))
    elif explicit_env_include:
        user_include = list(dict.fromkeys(env_include))
    elif selection_present:
        user_include = selection_include
    else:
        user_include = []

    if args.exclude:
        user_exclude = list(dict.fromkeys(args.exclude))
    elif explicit_env_exclude:
        user_exclude = list(dict.fromkeys(env_exclude))
    elif selection_present:
        user_exclude = selection_exclude
    else:
        user_exclude = []

    unknown_profiles = [name for name in active_profiles if name not in normalized_profiles]
    if unknown_profiles:
        raise SystemExit(
            f"unknown profile name(s): {', '.join(sorted(unknown_profiles))}"
        )

    mandatory_set = resolve_matches(mandatory, skill_ids, "mandatory")

    profile_include_entries: list[str] = []
    profile_exclude_entries: list[str] = []
    for name in active_profiles:
        profile_include_entries.extend(normalized_profiles[name]["include"])  # type: ignore[arg-type]
        profile_exclude_entries.extend(normalized_profiles[name]["exclude"])  # type: ignore[arg-type]

    profile_include_set = resolve_matches(
        profile_include_entries, skill_ids, "profile include"
    )
    profile_exclude_set = resolve_matches(
        profile_exclude_entries, skill_ids, "profile exclude"
    )
    user_include_set = resolve_matches(user_include, skill_ids, "user include")
    user_exclude_set = resolve_matches(user_exclude, skill_ids, "user exclude")

    final_set = set(mandatory_set)
    final_set.update(profile_include_set)
    final_set.update(user_include_set)
    final_set.difference_update(profile_exclude_set)
    final_set.difference_update(user_exclude_set)
    final_set.update(mandatory_set)

    if not final_set and not mandatory_set:
        raise SystemExit("selection resolved to zero skills")

    selected_skills = sorted(final_set)
    mode = "selected"

    write_skill_list(output_list, selected_skills)
    write_shell_env(
        output_env,
        {
            "RESOLVED_SYNC_MODE": mode,
            "RESOLVED_PROFILES": join_list(active_profiles),
            "RESOLVED_INCLUDE": join_list(user_include),
            "RESOLVED_EXCLUDE": join_list(user_exclude),
            "RESOLVED_MANDATORY": join_list(mandatory),
            "RESOLVED_SELECTION_FILE": selection_file_value,
            "RESOLVED_SELECTION_HASH": selection_hash(
                mode,
                active_profiles,
                user_include,
                user_exclude,
                mandatory,
                selection_file_value,
            ),
            "RESOLVED_SKILL_COUNT": str(len(selected_skills)),
        },
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
