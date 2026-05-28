#!/bin/bash
# Archive completed Ralph run directories.
#
# Usage:
#   ./archive-runs.sh [--dry-run] [--archive-root <path>] [--stories-only]
#
# By default, a run is archived only when every PRD story passes and merge-back
# is complete. --stories-only relaxes that to "all PRD stories pass".

set -e

DRY_RUN="false"
STORIES_ONLY="false"
ARCHIVE_ROOT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN="true"
      shift
      ;;
    --stories-only)
      STORIES_ONLY="true"
      shift
      ;;
    --archive-root)
      if [[ $# -lt 2 || "$2" == -* ]]; then
        echo "Error: --archive-root requires a path." >&2
        exit 1
      fi
      ARCHIVE_ROOT="$2"
      shift 2
      ;;
    --archive-root=*)
      ARCHIVE_ROOT="${1#*=}"
      if [[ -z "$ARCHIVE_ROOT" ]]; then
        echo "Error: --archive-root requires a path." >&2
        exit 1
      fi
      shift
      ;;
    -h|--help)
      sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "Error: Unknown argument '$1'" >&2
      exit 1
      ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RALPH_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$RALPH_ROOT/.." && pwd)"
RUNS_ROOT="$RALPH_ROOT/runs"

if [[ -z "$ARCHIVE_ROOT" ]]; then
  ARCHIVE_ROOT="$RALPH_ROOT/archive"
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "Error: jq is required." >&2
  exit 1
fi

run_prd_all_passed() {
  local prd_file="$1"

  jq -e '
    (.userStories | length) > 0
    and (.userStories | all(.passes == true))
  ' "$prd_file" >/dev/null 2>&1
}

run_merge_back_complete() {
  local run_dir="$1"
  local prd_file="$run_dir/prd.json"
  local state_file="$run_dir/state.json"
  local marker_file="$run_dir/.merge-back-done"
  local target_branch
  local base_branch

  target_branch=$(jq -r '.branchName // empty' "$prd_file" 2>/dev/null || echo "")
  base_branch=$(jq -r '.baseBranch // empty' "$state_file" 2>/dev/null || echo "")

  if [[ -z "$target_branch" || -z "$base_branch" || "$target_branch" == "$base_branch" ]]; then
    return 0
  fi

  if [[ -f "$marker_file" ]] \
    && grep -qx "status=done" "$marker_file" \
    && grep -qx "base_branch=$base_branch" "$marker_file" \
    && grep -qx "target_branch=$target_branch" "$marker_file"; then
    return 0
  fi

  if git -C "$REPO_ROOT" rev-parse --verify "$base_branch" >/dev/null 2>&1 \
    && git -C "$REPO_ROOT" rev-parse --verify "$target_branch" >/dev/null 2>&1 \
    && git -C "$REPO_ROOT" merge-base --is-ancestor "$target_branch" "$base_branch"; then
    return 0
  fi

  return 1
}

run_is_archivable() {
  local run_dir="$1"

  run_prd_all_passed "$run_dir/prd.json" || return 1

  if [[ "$STORIES_ONLY" == "true" ]]; then
    return 0
  fi

  run_merge_back_complete "$run_dir"
}

lock_is_active() {
  local run_id="$1"
  local lock_dir="$RALPH_ROOT/locks/run-$run_id.lock"
  local pid

  if [[ ! -d "$lock_dir" ]]; then
    return 1
  fi

  pid="$(cat "$lock_dir/pid" 2>/dev/null || true)"
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

unique_archive_dir() {
  local archive_batch="$1"
  local run_id="$2"
  local target="$archive_batch/$run_id"
  local suffix=2

  while [[ -e "$target" ]]; do
    target="$archive_batch/$run_id-$suffix"
    suffix=$((suffix + 1))
  done

  echo "$target"
}

archive_run() {
  local run_dir="$1"
  local archive_batch="$2"
  local run_id
  local target_dir
  local tmp_state
  local archived_at

  run_id="$(basename "$run_dir")"
  target_dir="$(unique_archive_dir "$archive_batch" "$run_id")"

  if [[ "$DRY_RUN" == "true" ]]; then
    printf "Would archive: %s -> %s\n" "$run_id" "$target_dir"
    return
  fi

  mkdir -p "$archive_batch"

  if [[ -f "$run_dir/state.json" ]]; then
    archived_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    tmp_state="$(mktemp)"
    jq \
      --arg status "archived" \
      --arg archivedAt "$archived_at" \
      '. + {status: $status, archivedAt: $archivedAt}' \
      "$run_dir/state.json" > "$tmp_state"
    mv "$tmp_state" "$run_dir/state.json"
  fi

  mv "$run_dir" "$target_dir"
  printf "Archived: %s -> %s\n" "$run_id" "$target_dir"
}

if [[ ! -d "$RUNS_ROOT" ]]; then
  echo "No Ralph runs directory found: $RUNS_ROOT"
  exit 0
fi

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
ARCHIVE_BATCH="$ARCHIVE_ROOT/$TIMESTAMP"
ARCHIVABLE_RUNS=()
SKIPPED_LOCKED=()

while IFS= read -r prd_file; do
  run_dir="$(dirname "$prd_file")"
  run_id="$(basename "$run_dir")"

  if lock_is_active "$run_id"; then
    SKIPPED_LOCKED+=("$run_id")
    continue
  fi

  if run_is_archivable "$run_dir"; then
    ARCHIVABLE_RUNS+=("$run_dir")
  fi
done < <(find "$RUNS_ROOT" -mindepth 2 -maxdepth 2 -type f -name prd.json -print | sort)

if [[ "${#ARCHIVABLE_RUNS[@]}" -eq 0 ]]; then
  echo "No completed Ralph runs to archive."
else
  for run_dir in "${ARCHIVABLE_RUNS[@]}"; do
    archive_run "$run_dir" "$ARCHIVE_BATCH"
  done
fi

if [[ "${#SKIPPED_LOCKED[@]}" -gt 0 ]]; then
  echo ""
  echo "Skipped active locked runs:"
  printf "  - %s\n" "${SKIPPED_LOCKED[@]}"
fi

if [[ "$DRY_RUN" == "true" && "${#ARCHIVABLE_RUNS[@]}" -gt 0 ]]; then
  echo ""
  echo "Dry run only. Rerun without --dry-run to archive these runs."
fi
