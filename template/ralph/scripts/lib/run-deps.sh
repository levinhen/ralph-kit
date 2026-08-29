#!/bin/bash

# Shared helpers for judging whether a Ralph run is finished, and whether one
# run's dependencies (`dependsOnRuns`) have landed on the base branch yet.
#
# Callers reach here from very different setups - ralph.sh has the full RALPH_ROOT
# / REPO_ROOT globals, archive-runs.sh sets them up itself, lint-prd.sh has only a
# file path - so the functions take their roots as parameters instead of reading
# globals. `run_merge_back_complete` keeps its single-argument form working by
# falling back to $REPO_ROOT.

# Every story in a run PRD is marked passes=true.
run_prd_all_passed() {
  local prd_file="$1"

  jq -e '
    (.userStories | length) > 0
    and (.userStories | all(.passes == true))
  ' "$prd_file" >/dev/null 2>&1
}

# The run's branch has landed on the base branch it was cut from: either the
# run wrote its merge-back marker, or the branch is already an ancestor of the
# base. A run with no branch of its own has nothing to merge back.
run_merge_back_complete() {
  local run_dir="$1"
  local repo_root="${2:-$REPO_ROOT}"
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

  if git -C "$repo_root" rev-parse --verify "$base_branch" >/dev/null 2>&1 \
    && git -C "$repo_root" rev-parse --verify "$target_branch" >/dev/null 2>&1 \
    && git -C "$repo_root" merge-base --is-ancestor "$target_branch" "$base_branch"; then
    return 0
  fi

  return 1
}

# Print the archive directory of an already-archived run, or nothing.
# Two layouts count as archived:
#   ralph/archive/<date>-<run_id>/          consolidation archiving in ralph.sh
#   ralph/archive/<batch-timestamp>/<run_id>/   archive-runs.sh batches
find_archived_run_dir() {
  local ralph_root="$1"
  local run_id="$2"
  local archive_root="$ralph_root/archive"
  local candidate

  if [[ -z "$run_id" || ! -d "$archive_root" ]]; then
    return 0
  fi

  while IFS= read -r candidate; do
    [[ -d "$candidate" ]] || continue
    printf '%s\n' "$candidate"
    return 0
  done < <(find "$archive_root" -mindepth 1 -maxdepth 1 -type d \
    -name "[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-$run_id" 2>/dev/null | sort -r)

  while IFS= read -r candidate; do
    [[ -d "$candidate" ]] || continue
    printf '%s\n' "$candidate"
    return 0
  done < <(find "$archive_root" -mindepth 2 -maxdepth 2 -type d \
    -name "$run_id" 2>/dev/null | sort -r)

  return 0
}

# A run listed in another run's `dependsOnRuns` is satisfied once its changes
# are on the base branch: either the live run dir is finished and merged back,
# or the run has already been archived.
run_dependency_satisfied() {
  local ralph_root="$1"
  local repo_root="$2"
  local run_id="$3"
  local run_dir="$ralph_root/runs/$run_id"

  if [[ -f "$run_dir/prd.json" ]] \
    && run_prd_all_passed "$run_dir/prd.json" \
    && run_merge_back_complete "$run_dir" "$repo_root"; then
    return 0
  fi

  if [[ -n "$(find_archived_run_dir "$ralph_root" "$run_id")" ]]; then
    return 0
  fi

  return 1
}
