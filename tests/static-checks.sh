#!/usr/bin/env bash
#
# Fast, dependency-light checks for syntax and generated-copy drift. Keep this
# gate cheap enough to run before the integration suite.

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

repo_files() {
  local name_pattern="$1"

  find "$REPO_ROOT" \
    \( -path "$REPO_ROOT/.git" -o -path "$REPO_ROOT/node_modules" \) -prune -o \
    -type f -name "$name_pattern" -print0
}

echo "Checking Bash syntax..."
repo_files '*.sh' | while IFS= read -r -d '' file; do
  bash -n "$file"
done

echo "Checking Node syntax..."
find "$REPO_ROOT" \
  \( -path "$REPO_ROOT/.git" -o -path "$REPO_ROOT/node_modules" \) -prune -o \
  -type f \( -name '*.js' -o -name '*.mjs' \) -print0 |
  while IFS= read -r -d '' file; do
    node --check "$file" >/dev/null
  done

check_canonical_skill() {
  local skill_name="$1"
  local canonical="$REPO_ROOT/template/.agents/skills/$skill_name/SKILL.md"
  local duplicate="$REPO_ROOT/template/.claude/skills/$skill_name/SKILL.md"

  if [[ ! -f "$canonical" ]]; then
    echo "Canonical Skill is missing: $canonical" >&2
    return 1
  fi
  if [[ -e "$duplicate" ]]; then
    echo "Skill '$skill_name' has an editable duplicate: $duplicate" >&2
    echo "The installer projects the canonical .agents source to .claude." >&2
    return 1
  fi
}

echo "Checking canonical Skill sources..."
check_canonical_skill ralph
check_canonical_skill prd

echo "Checking JSON syntax..."
repo_files '*.json' | while IFS= read -r -d '' file; do
  node -e '
    const fs = require("node:fs");
    JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  ' "$file"
done

echo "Static checks passed."
