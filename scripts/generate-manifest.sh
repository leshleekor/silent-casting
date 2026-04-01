#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILLS_DIR="${SKILLS_DIR:-$ROOT_DIR/skills}"

if [[ ! -d "$SKILLS_DIR" ]]; then
  printf 'skills directory not found: %s\n' "$SKILLS_DIR" >&2
  exit 1
fi

SKILLS_DIR="$(cd "$SKILLS_DIR" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SKILLS_DIR/.." && pwd)}"
OUTPUT_FILE="${OUTPUT_FILE:-$REPO_ROOT/manifest.json}"

tmp_file="$(mktemp)"
generated_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
version="$(date -u +"%Y.%m.%d")"
commit="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || printf 'unknown')"

{
  printf '{\n'
  printf '  "version": "%s",\n' "$version"
  printf '  "commit": "%s",\n' "$commit"
  printf '  "generated_at": "%s",\n' "$generated_at"
  printf '  "skills": [\n'
} > "$tmp_file"

first=1
while IFS= read -r skill_file; do
  rel_path="${skill_file#$REPO_ROOT/}"
  skill_id="${rel_path#skills/}"
  skill_id="${skill_id%/SKILL.md}"
  hash="$(shasum -a 256 "$skill_file" | awk '{print $1}')"

  if [[ "$first" -eq 0 ]]; then
    printf ',\n' >> "$tmp_file"
  fi
  first=0

  printf '    {\n' >> "$tmp_file"
  printf '      "id": "%s",\n' "$skill_id" >> "$tmp_file"
  printf '      "path": "%s",\n' "$rel_path" >> "$tmp_file"
  printf '      "hash": "sha256-%s"\n' "$hash" >> "$tmp_file"
  printf '    }' >> "$tmp_file"
done < <(find "$SKILLS_DIR" -name SKILL.md | sort)

{
  printf '\n'
  printf '  ]\n'
  printf '}\n'
} >> "$tmp_file"

mv "$tmp_file" "$OUTPUT_FILE"
printf 'manifest written to %s\n' "$OUTPUT_FILE"
