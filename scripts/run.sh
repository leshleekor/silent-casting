#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_SCRIPT_PATH="$SCRIPT_DIR/run.sh"
BOOTSTRAP_HELPER="$SCRIPT_DIR/bootstrap-hooks.py"
SELECTION_HELPER="$SCRIPT_DIR/resolve-selection.py"
BOOTSTRAP=0
PRINT_SELECTION=0
CLI_SELECTION_FILE=""
CLI_SELECTION_FILE_EXPLICIT=0
SELECTION_FILE_PATH=""
SELECTION_FILE_REQUIRED=0
SELECTION_LIST_FILE=""
CURRENT_SKILL_LIST_FILE=""
CLI_PROFILES=()
CLI_INCLUDE=()
CLI_EXCLUDE=()

RESOLVED_SYNC_MODE="all"
RESOLVED_PROFILES=""
RESOLVED_INCLUDE=""
RESOLVED_EXCLUDE=""
RESOLVED_MANDATORY=""
RESOLVED_SELECTION_FILE=""
RESOLVED_SELECTION_HASH=""
RESOLVED_SKILL_COUNT="0"

usage() {
  cat <<'EOF'
Usage: run.sh [options]

Options:
  --target claude|codex|all       Sync target (default: all)
  --claude-dir PATH               Claude skills install dir (default: ~/.claude/skills)
  --codex-dir PATH                Codex skills install dir (default: ~/.agents/skills)
  --bootstrap                     Register SessionStart hooks
  --profile NAME                  Enable a profile from profiles.json (repeatable)
  --include SKILL_OR_PATTERN      Add a skill or glob pattern (repeatable)
  --exclude SKILL_OR_PATTERN      Exclude a skill or glob pattern (repeatable)
  --selection-file PATH           Override selection.json path
  --print-selection               Print the resolved selection and exit
  --help, -h                      Show this help

Environment:
  SKILLS_PROFILE                  Comma-separated profile list
  SKILLS_INCLUDE                  Comma-separated include list
  SKILLS_EXCLUDE                  Comma-separated exclude list
  SKILLS_SELECTION_FILE           Override selection.json path

Notes:
  If you only use one agent, prefer --target claude or --target codex.
  SKILLS_SYNC_DIR controls the internal sync workspace.
  --bootstrap registers SessionStart hooks in user-level Claude/Codex config.
  If profiles.json exists, selective sync is enabled and requires python3.
EOF
}

log() {
  printf '[silent-casting] %s\n' "$1"
}

fail() {
  printf '[silent-casting] ERROR: %s\n' "$1" >&2
  exit 1
}

shell_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

csv_or_none() {
  local value="$1"
  if [[ -n "$value" ]]; then
    printf '%s' "$value"
  else
    printf '(none)'
  fi
}

SKILLS_GIT_URL="${SKILLS_GIT_URL:-}"
SKILLS_BRANCH="${SKILLS_BRANCH:-main}"
SKILLS_SYNC_DIR="${SKILLS_SYNC_DIR:-${SKILLS_HOME:-$HOME/.company-skills}}"
SKILLS_REPO_DIR="${SKILLS_REPO_DIR:-$SKILLS_SYNC_DIR/repo}"
SKILLS_STATE_DIR="${SKILLS_STATE_DIR:-$SKILLS_SYNC_DIR/state}"
SKILLS_MANIFEST_CACHE="${SKILLS_MANIFEST_CACHE:-$SKILLS_SYNC_DIR/manifest.json}"
SKILLS_TARGET="${SKILLS_TARGET:-all}"
CLAUDE_SKILLS_DIR="${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}"
CODEX_SKILLS_DIR="${CODEX_SKILLS_DIR:-$HOME/.agents/skills}"

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --target)
        [[ $# -ge 2 ]] || fail "--target requires a value"
        SKILLS_TARGET="$2"
        shift 2
        ;;
      --claude-dir)
        [[ $# -ge 2 ]] || fail "--claude-dir requires a value"
        CLAUDE_SKILLS_DIR="$2"
        shift 2
        ;;
      --codex-dir)
        [[ $# -ge 2 ]] || fail "--codex-dir requires a value"
        CODEX_SKILLS_DIR="$2"
        shift 2
        ;;
      --profile)
        [[ $# -ge 2 ]] || fail "--profile requires a value"
        CLI_PROFILES+=("$2")
        shift 2
        ;;
      --include)
        [[ $# -ge 2 ]] || fail "--include requires a value"
        CLI_INCLUDE+=("$2")
        shift 2
        ;;
      --exclude)
        [[ $# -ge 2 ]] || fail "--exclude requires a value"
        CLI_EXCLUDE+=("$2")
        shift 2
        ;;
      --selection-file)
        [[ $# -ge 2 ]] || fail "--selection-file requires a value"
        CLI_SELECTION_FILE="$2"
        CLI_SELECTION_FILE_EXPLICIT=1
        shift 2
        ;;
      --print-selection)
        PRINT_SELECTION=1
        shift
        ;;
      --bootstrap)
        BOOTSTRAP=1
        shift
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        fail "unknown option: $1"
        ;;
    esac
  done
}

validate_target() {
  case "$SKILLS_TARGET" in
    claude|codex|all)
      ;;
    *)
      fail "SKILLS_TARGET must be one of: claude, codex, all"
      ;;
  esac
}

resolve_selection_file_settings() {
  if [[ "$CLI_SELECTION_FILE_EXPLICIT" -eq 1 ]]; then
    SELECTION_FILE_PATH="$CLI_SELECTION_FILE"
    SELECTION_FILE_REQUIRED=1
    return
  fi

  if [[ -n "${SKILLS_SELECTION_FILE:-}" ]]; then
    SELECTION_FILE_PATH="$SKILLS_SELECTION_FILE"
    SELECTION_FILE_REQUIRED=1
    return
  fi

  SELECTION_FILE_PATH="$SKILLS_SYNC_DIR/selection.json"
  SELECTION_FILE_REQUIRED=0
}

selection_support_requested() {
  [[ -f "$SKILLS_REPO_DIR/profiles.json" ]] && return 0
  [[ "$PRINT_SELECTION" -eq 1 ]] && return 0
  [[ "${#CLI_PROFILES[@]}" -gt 0 ]] && return 0
  [[ "${#CLI_INCLUDE[@]}" -gt 0 ]] && return 0
  [[ "${#CLI_EXCLUDE[@]}" -gt 0 ]] && return 0
  [[ -n "${SKILLS_PROFILE:-}" ]] && return 0
  [[ -n "${SKILLS_INCLUDE:-}" ]] && return 0
  [[ -n "${SKILLS_EXCLUDE:-}" ]] && return 0
  [[ "$SELECTION_FILE_REQUIRED" -eq 1 ]] && return 0
  [[ -f "$SELECTION_FILE_PATH" ]] && return 0
  return 1
}

build_full_skill_list() {
  CURRENT_SKILL_LIST_FILE="$(mktemp "$SKILLS_SYNC_DIR/full-list.XXXXXX")"
  find "$SKILLS_REPO_DIR/skills" -name SKILL.md | sort | sed "s#${SKILLS_REPO_DIR}/skills/##; s#/SKILL.md##" > "$CURRENT_SKILL_LIST_FILE"
}

managed_skill_list_file() {
  local target_name="$1"
  printf '%s/%s-managed-skills.txt' "$SKILLS_STATE_DIR" "$target_name"
}

validate_skill_id() {
  local skill_id="$1"

  [[ -n "$skill_id" ]] || fail "empty skill id is not allowed"
  [[ "$skill_id" != /* ]] || fail "absolute skill id is not allowed: $skill_id"
  [[ "$skill_id" != *\\* ]] || fail "backslash in skill id is not allowed: $skill_id"
  [[ "$skill_id" != */ ]] || fail "trailing slash in skill id is not allowed: $skill_id"

  case "/$skill_id/" in
    *"/../"*|*"/./"*)
      fail "relative path segment in skill id is not allowed: $skill_id"
      ;;
  esac
}

validate_skill_list_file() {
  local list_file="$1"
  local skill_id

  while IFS= read -r skill_id; do
    [[ -n "$skill_id" ]] || continue
    validate_skill_id "$skill_id"
  done < "$list_file"
}

skill_list_contains() {
  local list_file="$1"
  local skill_id="$2"

  grep -Fx -- "$skill_id" "$list_file" >/dev/null 2>&1
}

assert_no_symlink_parent_dirs() {
  local root_dir="$1"
  local skill_id="$2"
  local parent_rel="${skill_id%/*}"
  local current_dir="$root_dir"
  local segment

  if [[ "$parent_rel" == "$skill_id" ]]; then
    return
  fi

  while [[ -n "$parent_rel" ]]; do
    segment="${parent_rel%%/*}"
    current_dir="$current_dir/$segment"
    if [[ -L "$current_dir" ]]; then
      fail "refusing to sync through symlinked skill parent: $current_dir"
    fi
    if [[ "$parent_rel" == "$segment" ]]; then
      break
    fi
    parent_rel="${parent_rel#*/}"
  done
}

remove_empty_parent_dirs() {
  local root_dir="$1"
  local current_dir="$2"

  while [[ "$current_dir" != "$root_dir" && "$current_dir" != "." ]]; do
    if find "$current_dir" -mindepth 1 -maxdepth 1 | read -r _; then
      break
    fi
    rmdir "$current_dir" 2>/dev/null || break
    current_dir="$(dirname "$current_dir")"
  done
}

remove_skill_from_tree() {
  local tree_dir="$1"
  local skill_id="$2"
  local skill_dir="$tree_dir/$skill_id"

  validate_skill_id "$skill_id"
  assert_no_symlink_parent_dirs "$tree_dir" "$skill_id"

  if [[ -e "$skill_dir" || -L "$skill_dir" ]]; then
    rm -rf "$skill_dir"
    remove_empty_parent_dirs "$tree_dir" "$(dirname "$skill_dir")"
  fi
}

stage_selected_skills() {
  local staging_dir="$1"
  local selection_list_file="$2"
  local skill_id
  local source_dir
  local staged_dir

  mkdir -p "$staging_dir"

  while IFS= read -r skill_id; do
    [[ -n "$skill_id" ]] || continue
    validate_skill_id "$skill_id"

    source_dir="$SKILLS_REPO_DIR/skills/$skill_id"
    staged_dir="$staging_dir/$skill_id"

    [[ -d "$source_dir" ]] || fail "selected skill directory not found: $source_dir"
    mkdir -p "$(dirname "$staged_dir")"
    cp -R "$source_dir" "$staged_dir"
  done < "$selection_list_file"
}

install_staged_skill() {
  local target_dir="$1"
  local staging_dir="$2"
  local skill_id="$3"
  local destination_dir="$target_dir/$skill_id"
  local staged_dir="$staging_dir/$skill_id"
  local backup_dir="$staging_dir/.backup/$skill_id"
  local has_backup=0

  [[ -d "$staged_dir" ]] || fail "staged skill directory not found: $staged_dir"

  assert_no_symlink_parent_dirs "$target_dir" "$skill_id"

  if [[ -e "$destination_dir" || -L "$destination_dir" ]]; then
    mkdir -p "$(dirname "$backup_dir")"
    mv "$destination_dir" "$backup_dir"
    has_backup=1
  fi

  if ! mkdir -p "$(dirname "$destination_dir")"; then
    if [[ "$has_backup" -eq 1 ]]; then
      mkdir -p "$(dirname "$destination_dir")"
      mv "$backup_dir" "$destination_dir"
    fi
    fail "failed to create target parent for skill: $skill_id"
  fi

  if ! mv "$staged_dir" "$destination_dir"; then
    if [[ "$has_backup" -eq 1 ]]; then
      rm -rf "$destination_dir"
      mkdir -p "$(dirname "$destination_dir")"
      mv "$backup_dir" "$destination_dir"
    fi
    fail "failed to install skill: $skill_id"
  fi

  if [[ "$has_backup" -eq 1 ]]; then
    rm -rf "$backup_dir"
  fi
}

sync_target_tree() {
  local target_name="$1"
  local target_dir="$2"
  local managed_file
  local staging_dir
  local skill_id

  managed_file="$(managed_skill_list_file "$target_name")"
  staging_dir="$(mktemp -d "$SKILLS_SYNC_DIR/${target_name}.skills.XXXXXX")"

  validate_skill_list_file "$CURRENT_SKILL_LIST_FILE"
  if [[ -f "$managed_file" ]]; then
    validate_skill_list_file "$managed_file"
  fi

  stage_selected_skills "$staging_dir" "$CURRENT_SKILL_LIST_FILE"
  mkdir -p "$target_dir"

  while IFS= read -r skill_id; do
    [[ -n "$skill_id" ]] || continue
    install_staged_skill "$target_dir" "$staging_dir" "$skill_id"
  done < "$CURRENT_SKILL_LIST_FILE"

  if [[ -f "$managed_file" ]]; then
    while IFS= read -r skill_id; do
      [[ -n "$skill_id" ]] || continue
      if ! skill_list_contains "$CURRENT_SKILL_LIST_FILE" "$skill_id"; then
        remove_skill_from_tree "$target_dir" "$skill_id"
      fi
    done < "$managed_file"
  fi

  rm -rf "$staging_dir"
}

write_managed_skill_list() {
  local target_name="$1"
  local managed_file
  local tmp_file

  managed_file="$(managed_skill_list_file "$target_name")"
  tmp_file="$(mktemp "$SKILLS_STATE_DIR/${target_name}-managed-skills.XXXXXX")"
  cp "$CURRENT_SKILL_LIST_FILE" "$tmp_file"
  mv "$tmp_file" "$managed_file"
}

stage_target() {
  local target_name="$1"
  local target_dir="$2"

  sync_target_tree "$target_name" "$target_dir"
  write_managed_skill_list "$target_name"
}

has_target_sync_state() {
  local target_name="$1"
  local state_file="$SKILLS_STATE_DIR/${target_name}-last-sync.env"
  local managed_file

  managed_file="$(managed_skill_list_file "$target_name")"
  [[ -f "$state_file" && -f "$managed_file" ]]
}

has_previous_sync_state() {
  case "$SKILLS_TARGET" in
    claude)
      has_target_sync_state "claude"
      ;;
    codex)
      has_target_sync_state "codex"
      ;;
    all)
      has_target_sync_state "claude" && has_target_sync_state "codex"
      ;;
  esac
}

cache_manifest() {
  if [[ -f "$SKILLS_REPO_DIR/manifest.json" ]]; then
    cp "$SKILLS_REPO_DIR/manifest.json" "$SKILLS_MANIFEST_CACHE"
  fi
}

clean_cached_repo() {
  local repo_real
  local sync_real

  repo_real="$(cd "$SKILLS_REPO_DIR" && pwd -P)"
  sync_real="$(cd "$SKILLS_SYNC_DIR" && pwd -P)"

  case "$repo_real" in
    "$sync_real"/*)
      git -C "$SKILLS_REPO_DIR" clean -ffdx
      ;;
    *)
      fail "refusing to clean cache repo outside SKILLS_SYNC_DIR: $SKILLS_REPO_DIR"
      ;;
  esac
}

write_sync_state() {
  local target_name="$1"
  local target_dir="$2"
  local commit
  local state_file

  commit="$(git -C "$SKILLS_REPO_DIR" rev-parse HEAD)"
  state_file="$SKILLS_STATE_DIR/${target_name}-last-sync.env"

  cat > "$state_file" <<EOF
LAST_SYNC_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
LAST_SYNC_COMMIT=$commit
LAST_SYNC_BRANCH=$SKILLS_BRANCH
LAST_SYNC_TARGET=$target_name
LAST_SYNC_PATH=$target_dir
LAST_SYNC_MODE=$RESOLVED_SYNC_MODE
LAST_SYNC_PROFILE_SET=$RESOLVED_PROFILES
LAST_SYNC_INCLUDE=$RESOLVED_INCLUDE
LAST_SYNC_EXCLUDE=$RESOLVED_EXCLUDE
LAST_SYNC_SELECTION_FILE=$RESOLVED_SELECTION_FILE
LAST_SYNC_SELECTION_HASH=$RESOLVED_SELECTION_HASH
LAST_SYNC_SKILL_COUNT=$RESOLVED_SKILL_COUNT
EOF
}

sync_targets() {
  case "$SKILLS_TARGET" in
    claude)
      stage_target "claude" "$CLAUDE_SKILLS_DIR"
      write_sync_state "claude" "$CLAUDE_SKILLS_DIR"
      ;;
    codex)
      stage_target "codex" "$CODEX_SKILLS_DIR"
      write_sync_state "codex" "$CODEX_SKILLS_DIR"
      ;;
    all)
      stage_target "claude" "$CLAUDE_SKILLS_DIR"
      write_sync_state "claude" "$CLAUDE_SKILLS_DIR"
      stage_target "codex" "$CODEX_SKILLS_DIR"
      write_sync_state "codex" "$CODEX_SKILLS_DIR"
      ;;
  esac
}

build_hook_command() {
  local target="$1"
  local marker="silent-casting-managed:${target}"
  local command=""
  local profile
  local include
  local exclude

  command+="SKILLS_GIT_URL=$(shell_quote "$SKILLS_GIT_URL") "
  command+="SKILLS_BRANCH=$(shell_quote "$SKILLS_BRANCH") "
  command+="SKILLS_SYNC_DIR=$(shell_quote "$SKILLS_SYNC_DIR") "

  if [[ "$CLI_SELECTION_FILE_EXPLICIT" -eq 0 && "$SELECTION_FILE_REQUIRED" -eq 1 ]]; then
    command+="SKILLS_SELECTION_FILE=$(shell_quote "$SELECTION_FILE_PATH") "
  fi
  if [[ "${SKILLS_PROFILE+x}" == "x" ]]; then
    command+="SKILLS_PROFILE=$(shell_quote "$SKILLS_PROFILE") "
  fi
  if [[ "${SKILLS_INCLUDE+x}" == "x" ]]; then
    command+="SKILLS_INCLUDE=$(shell_quote "$SKILLS_INCLUDE") "
  fi
  if [[ "${SKILLS_EXCLUDE+x}" == "x" ]]; then
    command+="SKILLS_EXCLUDE=$(shell_quote "$SKILLS_EXCLUDE") "
  fi

  case "$target" in
    claude)
      command+="CLAUDE_SKILLS_DIR=$(shell_quote "$CLAUDE_SKILLS_DIR") "
      ;;
    codex)
      command+="CODEX_SKILLS_DIR=$(shell_quote "$CODEX_SKILLS_DIR") "
      ;;
  esac

  command+="bash $(shell_quote "$RUN_SCRIPT_PATH") --target $target"
  if [[ "$CLI_SELECTION_FILE_EXPLICIT" -eq 1 ]]; then
    command+=" --selection-file $(shell_quote "$CLI_SELECTION_FILE")"
  fi
  if [[ "${#CLI_PROFILES[@]}" -gt 0 ]]; then
    for profile in "${CLI_PROFILES[@]}"; do
      command+=" --profile $(shell_quote "$profile")"
    done
  fi
  if [[ "${#CLI_INCLUDE[@]}" -gt 0 ]]; then
    for include in "${CLI_INCLUDE[@]}"; do
      command+=" --include $(shell_quote "$include")"
    done
  fi
  if [[ "${#CLI_EXCLUDE[@]}" -gt 0 ]]; then
    for exclude in "${CLI_EXCLUDE[@]}"; do
      command+=" --exclude $(shell_quote "$exclude")"
    done
  fi
  command+=" # $marker"
  printf '%s' "$command"
}

bootstrap_hooks() {
  command -v python3 >/dev/null 2>&1 || fail "python3 is required for --bootstrap"
  [[ -f "$BOOTSTRAP_HELPER" ]] || fail "bootstrap helper not found: $BOOTSTRAP_HELPER"

  local args=(--target "$SKILLS_TARGET")

  case "$SKILLS_TARGET" in
    claude)
      args+=(--claude-command "$(build_hook_command claude)")
      ;;
    codex)
      args+=(--codex-command "$(build_hook_command codex)")
      ;;
    all)
      args+=(--claude-command "$(build_hook_command claude)")
      args+=(--codex-command "$(build_hook_command codex)")
      ;;
  esac

  python3 "$BOOTSTRAP_HELPER" "${args[@]}"
  log "bootstrap complete"
}

resolve_selection() {
  local selection_env_file
  local profiles_file=""
  local args=()
  local profile
  local include
  local exclude

  command -v python3 >/dev/null 2>&1 || fail "python3 is required for selective sync"
  [[ -f "$SELECTION_HELPER" ]] || fail "selection helper not found: $SELECTION_HELPER"

  selection_env_file="$(mktemp "$SKILLS_SYNC_DIR/selection-env.XXXXXX")"
  SELECTION_LIST_FILE="$(mktemp "$SKILLS_SYNC_DIR/selection-list.XXXXXX")"

  if [[ -f "$SKILLS_REPO_DIR/profiles.json" ]]; then
    profiles_file="$SKILLS_REPO_DIR/profiles.json"
  fi

  args=(
    --skills-root "$SKILLS_REPO_DIR/skills"
    --selection-file "$SELECTION_FILE_PATH"
    --output-env "$selection_env_file"
    --output-list "$SELECTION_LIST_FILE"
  )

  if [[ -n "$profiles_file" ]]; then
    args+=(--profiles-file "$profiles_file")
  fi
  if [[ "$SELECTION_FILE_REQUIRED" -eq 1 ]]; then
    args+=(--selection-file-required)
  fi
  if [[ "${#CLI_PROFILES[@]}" -gt 0 ]]; then
    for profile in "${CLI_PROFILES[@]}"; do
      args+=(--profile "$profile")
    done
  fi
  if [[ "${#CLI_INCLUDE[@]}" -gt 0 ]]; then
    for include in "${CLI_INCLUDE[@]}"; do
      args+=(--include "$include")
    done
  fi
  if [[ "${#CLI_EXCLUDE[@]}" -gt 0 ]]; then
    for exclude in "${CLI_EXCLUDE[@]}"; do
      args+=(--exclude "$exclude")
    done
  fi

  python3 "$SELECTION_HELPER" "${args[@]}"
  # shellcheck disable=SC1090
  . "$selection_env_file"
  rm -f "$selection_env_file"
}

initialize_full_sync_defaults() {
  RESOLVED_SYNC_MODE="all"
  RESOLVED_PROFILES=""
  RESOLVED_INCLUDE=""
  RESOLVED_EXCLUDE=""
  RESOLVED_MANDATORY=""
  RESOLVED_SELECTION_FILE=""
  RESOLVED_SELECTION_HASH="full-sync"
  RESOLVED_SKILL_COUNT="$(find "$SKILLS_REPO_DIR/skills" -name SKILL.md | wc -l | tr -d ' ')"
  build_full_skill_list
}

print_selection() {
  local skill_id

  printf 'Selection mode: %s\n' "$RESOLVED_SYNC_MODE"
  printf 'Profiles: %s\n' "$(csv_or_none "$RESOLVED_PROFILES")"
  printf 'Mandatory: %s\n' "$(csv_or_none "$RESOLVED_MANDATORY")"
  printf 'Include: %s\n' "$(csv_or_none "$RESOLVED_INCLUDE")"
  printf 'Exclude: %s\n' "$(csv_or_none "$RESOLVED_EXCLUDE")"
  printf 'Selection file: %s\n' "$(csv_or_none "$RESOLVED_SELECTION_FILE")"
  printf 'Skill count: %s\n' "$RESOLVED_SKILL_COUNT"
  printf 'Selected skills:\n'

  if [[ -n "$SELECTION_LIST_FILE" && -f "$SELECTION_LIST_FILE" ]]; then
    while IFS= read -r skill_id; do
      [[ -n "$skill_id" ]] || continue
      printf -- '- %s\n' "$skill_id"
    done < "$SELECTION_LIST_FILE"
    return
  fi

  while IFS= read -r skill_id; do
    [[ -n "$skill_id" ]] || continue
    printf -- '- %s\n' "${skill_id#$SKILLS_REPO_DIR/skills/}"
  done < <(find "$SKILLS_REPO_DIR/skills" -name SKILL.md | sort | sed "s#${SKILLS_REPO_DIR}/skills/##; s#/SKILL.md##")
}

cleanup_selection_artifacts() {
  if [[ -n "$SELECTION_LIST_FILE" && -f "$SELECTION_LIST_FILE" ]]; then
    rm -f "$SELECTION_LIST_FILE"
  fi
  if [[ -n "$CURRENT_SKILL_LIST_FILE" && -f "$CURRENT_SKILL_LIST_FILE" ]]; then
    rm -f "$CURRENT_SKILL_LIST_FILE"
  fi
}

parse_args "$@"
validate_target
resolve_selection_file_settings

if [[ -z "$SKILLS_GIT_URL" ]]; then
  fail "SKILLS_GIT_URL is required"
fi

mkdir -p "$SKILLS_SYNC_DIR" "$SKILLS_STATE_DIR"
trap cleanup_selection_artifacts EXIT

sync_repo() {
  local current_origin

  if [[ ! -d "$SKILLS_REPO_DIR/.git" ]]; then
    log "cloning skills repository"
    git clone --branch "$SKILLS_BRANCH" --depth 1 "$SKILLS_GIT_URL" "$SKILLS_REPO_DIR"
    return
  fi

  log "updating skills repository"
  current_origin="$(git -C "$SKILLS_REPO_DIR" remote get-url origin 2>/dev/null || true)"
  if [[ "$current_origin" != "$SKILLS_GIT_URL" ]]; then
    log "updating skills repository origin"
    if [[ -n "$current_origin" ]]; then
      git -C "$SKILLS_REPO_DIR" remote set-url origin "$SKILLS_GIT_URL"
    else
      git -C "$SKILLS_REPO_DIR" remote add origin "$SKILLS_GIT_URL"
    fi
  fi
  git -C "$SKILLS_REPO_DIR" fetch origin "$SKILLS_BRANCH" --depth 1
  git -C "$SKILLS_REPO_DIR" checkout -q -B "$SKILLS_BRANCH" "origin/$SKILLS_BRANCH"
  # This repo is a cache mirror; force local branch to tracked remote tip.
  # Using pull --ff-only with shallow history can fail even when remote only advanced.
  git -C "$SKILLS_REPO_DIR" reset --hard "origin/$SKILLS_BRANCH"
  clean_cached_repo
}

main() {
  if [[ "$BOOTSTRAP" -eq 1 ]]; then
    bootstrap_hooks
  fi

  if ! sync_repo; then
    if has_previous_sync_state; then
      log "sync failed, keeping previous target directory"
      exit 0
    fi
    fail "sync failed and no previous Silent Casting sync state exists"
  fi

  [[ -d "$SKILLS_REPO_DIR/skills" ]] || fail "repository does not contain skills directory"

  if selection_support_requested; then
    resolve_selection
    CURRENT_SKILL_LIST_FILE="$SELECTION_LIST_FILE"
  else
    initialize_full_sync_defaults
  fi

  if [[ "$PRINT_SELECTION" -eq 1 ]]; then
    print_selection
    exit 0
  fi

  cache_manifest
  sync_targets
  log "sync mode: $RESOLVED_SYNC_MODE ($RESOLVED_SKILL_COUNT skills)"
  log "sync complete"
}

main "$@"
