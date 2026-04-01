#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_SCRIPT_PATH="$SCRIPT_DIR/run.sh"
BOOTSTRAP_HELPER="$SCRIPT_DIR/bootstrap-hooks.py"
BOOTSTRAP=0

usage() {
  cat <<'EOF'
Usage: run.sh [--target claude|codex|all] [--bootstrap] [--claude-dir PATH] [--codex-dir PATH]

Defaults:
  --target      all
  --claude-dir  ~/.claude/skills
  --codex-dir   ~/.agents/skills

Notes:
  If you only use one agent, prefer --target claude or --target codex.
  SKILLS_SYNC_DIR controls the internal sync workspace.
  --bootstrap registers SessionStart hooks in user-level Claude/Codex config.
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

copy_skills_tree() {
  local target_dir="$1"

  mkdir -p "$target_dir"
  cp -R "$SKILLS_REPO_DIR/skills/." "$target_dir/"
}

stage_target() {
  local target_name="$1"
  local target_dir="$2"
  local tmp_dir

  tmp_dir="$(mktemp -d "$SKILLS_SYNC_DIR/${target_name}.tmp.XXXXXX")"
  copy_skills_tree "$tmp_dir"

  mkdir -p "$(dirname "$target_dir")"
  rm -rf "$target_dir.prev"
  if [[ -e "$target_dir" ]]; then
    mv "$target_dir" "$target_dir.prev"
  fi

  mv "$tmp_dir" "$target_dir"
  rm -rf "$target_dir.prev"
}

has_previous_target() {
  case "$SKILLS_TARGET" in
    claude)
      [[ -d "$CLAUDE_SKILLS_DIR" ]]
      ;;
    codex)
      [[ -d "$CODEX_SKILLS_DIR" ]]
      ;;
    all)
      [[ -d "$CLAUDE_SKILLS_DIR" || -d "$CODEX_SKILLS_DIR" ]]
      ;;
  esac
}

cache_manifest() {
  if [[ -f "$SKILLS_REPO_DIR/manifest.json" ]]; then
    cp "$SKILLS_REPO_DIR/manifest.json" "$SKILLS_MANIFEST_CACHE"
  fi
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

  command+="SKILLS_GIT_URL=$(shell_quote "$SKILLS_GIT_URL") "
  command+="SKILLS_BRANCH=$(shell_quote "$SKILLS_BRANCH") "
  command+="SKILLS_SYNC_DIR=$(shell_quote "$SKILLS_SYNC_DIR") "

  case "$target" in
    claude)
      command+="CLAUDE_SKILLS_DIR=$(shell_quote "$CLAUDE_SKILLS_DIR") "
      ;;
    codex)
      command+="CODEX_SKILLS_DIR=$(shell_quote "$CODEX_SKILLS_DIR") "
      ;;
  esac

  command+="bash $(shell_quote "$RUN_SCRIPT_PATH") --target $target"
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

parse_args "$@"
validate_target

if [[ -z "$SKILLS_GIT_URL" ]]; then
  fail "SKILLS_GIT_URL is required"
fi

mkdir -p "$SKILLS_SYNC_DIR" "$SKILLS_STATE_DIR"

sync_repo() {
  if [[ ! -d "$SKILLS_REPO_DIR/.git" ]]; then
    log "cloning skills repository"
    git clone --branch "$SKILLS_BRANCH" --depth 1 "$SKILLS_GIT_URL" "$SKILLS_REPO_DIR"
    return
  fi

  log "updating skills repository"
  git -C "$SKILLS_REPO_DIR" fetch origin "$SKILLS_BRANCH" --depth 1
  git -C "$SKILLS_REPO_DIR" checkout -q "$SKILLS_BRANCH"
  # This repo is a cache mirror; force local branch to tracked remote tip.
  # Using pull --ff-only with shallow history can fail even when remote only advanced.
  git -C "$SKILLS_REPO_DIR" reset --hard "origin/$SKILLS_BRANCH"
}

main() {
  if [[ "$BOOTSTRAP" -eq 1 ]]; then
    bootstrap_hooks
  fi

  if ! sync_repo; then
    if has_previous_target; then
      log "sync failed, keeping previous target directory"
      exit 0
    fi
    fail "sync failed and no previous target directory exists"
  fi

  [[ -d "$SKILLS_REPO_DIR/skills" ]] || fail "repository does not contain skills directory"

  cache_manifest
  sync_targets
  log "sync complete"
}

main "$@"
