#!/bin/bash
# Create a run-scoped Ralph directory from an existing prd.json.
# Usage: ./create-run.sh [--force] <run_id> [source_prd_json]
#
# The closing lint checks the backlog's shape: story ids and the `dependsOn` /
# `dependsOnRuns` edges. A missing deps-audit.json is only a `WARN:` line, so a
# run created from a hand-written prd.json is ready to run without one.

set -e

FORCE="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force)
      FORCE="true"
      shift
      ;;
    -*)
      echo "Error: Unknown option '$1'"
      exit 1
      ;;
    *)
      break
      ;;
  esac
done

RUN_ID="${1:-}"
SOURCE_PRD="${2:-}"

if [[ -z "$RUN_ID" ]]; then
  echo "Usage: $0 [--force] <run_id> [source_prd_json]"
  exit 1
fi

if [[ ! "$RUN_ID" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "Error: Invalid run id '$RUN_ID'. Use only letters, numbers, dot, underscore, and dash."
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RALPH_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$RALPH_ROOT/.." && pwd)"

require_git_base() {
  if ! git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "Error: Ralph runs require a Git repository at $REPO_ROOT"
    echo "Initialize and commit a base first, for example:"
    echo "  git -C \"$REPO_ROOT\" init -b main"
    echo "  git -C \"$REPO_ROOT\" add ."
    echo "  git -C \"$REPO_ROOT\" commit -m \"Initial Ralph workspace\""
    exit 1
  fi

  if ! git -C "$REPO_ROOT" rev-parse --verify HEAD >/dev/null 2>&1; then
    echo "Error: Ralph runs require at least one Git commit in $REPO_ROOT"
    echo "Create the base commit before creating a run:"
    echo "  git -C \"$REPO_ROOT\" add ."
    echo "  git -C \"$REPO_ROOT\" commit -m \"Initial Ralph workspace\""
    exit 1
  fi

  if [[ -z "$(git -C "$REPO_ROOT" branch --show-current 2>/dev/null || echo "")" ]]; then
    echo "Error: Ralph cannot create a run from a detached HEAD in $REPO_ROOT"
    echo "Check out a local base branch first."
    exit 1
  fi
}

if [[ -z "$SOURCE_PRD" ]]; then
  SOURCE_PRD="$RALPH_ROOT/prd.json"
fi

if [[ ! -f "$SOURCE_PRD" ]]; then
  echo "Error: Source PRD not found: $SOURCE_PRD"
  exit 1
fi

require_git_base

RUN_DIR="$RALPH_ROOT/runs/$RUN_ID"
TARGET_PRD="$RUN_DIR/prd.json"
PROGRESS_FILE="$RUN_DIR/progress.txt"
PROGRESS_DIR="$RUN_DIR/progress"
SHARED_MEMORY_FILE="$PROGRESS_DIR/shared-memory.json"
STATE_FILE="$RUN_DIR/state.json"

if [[ -e "$RUN_DIR" && "$FORCE" != "true" ]]; then
  echo "Error: Ralph run already exists: $RUN_DIR"
  echo "Use --force to overwrite prd.json, progress.txt, progress/, and state.json for this run."
  exit 1
fi

mkdir -p "$RUN_DIR" "$PROGRESS_DIR"
cp "$SOURCE_PRD" "$TARGET_PRD"

{
  echo "# Ralph Progress Log"
  echo "Started: $(date)"
  echo "---"
} > "$PROGRESS_FILE"

echo '[]' > "$SHARED_MEMORY_FILE"

TARGET_BRANCH=$(jq -r '.branchName // empty' "$TARGET_PRD" 2>/dev/null || echo "")
BASE_BRANCH=$(git -C "$REPO_ROOT" branch --show-current 2>/dev/null || echo "")
BASE_SHA=$(git -C "$REPO_ROOT" rev-parse --verify HEAD 2>/dev/null || echo "")

jq -n \
  --arg runId "$RUN_ID" \
  --arg baseBranch "$BASE_BRANCH" \
  --arg baseSha "$BASE_SHA" \
  --arg targetBranch "$TARGET_BRANCH" \
  --arg status "ready" \
  '{
    runId: $runId,
    baseBranch: $baseBranch,
    baseSha: $baseSha,
    targetBranch: $targetBranch,
    status: $status
  }' > "$STATE_FILE"

echo "Created Ralph run: $RUN_ID"
echo "  PRD: $TARGET_PRD"
echo "  Progress: $PROGRESS_FILE"
echo "  Progress dir: $PROGRESS_DIR"
echo "  Shared memory: $SHARED_MEMORY_FILE"
echo "  State: $STATE_FILE"

# The run dir stays on disk when the lint fails: the PRD is what needs editing,
# and ralph.sh would refuse to start on it anyway.
if ! LINT_OUTPUT="$(bash "$SCRIPT_DIR/lint-prd.sh" --run "$RUN_ID" 2>&1)"; then
  printf '%s\n' "$LINT_OUTPUT"
  echo "Error: The new run's PRD failed validation: $TARGET_PRD"
  echo "Fix it, then recheck with: $SCRIPT_DIR/lint-prd.sh --run $RUN_ID"
  exit 1
fi

# Advisory lint findings are swallowed by the capture above; surface them.
printf '%s\n' "$LINT_OUTPUT" | grep '^WARN: ' || true

echo "Run with: $SCRIPT_DIR/ralph.sh --run $RUN_ID"
