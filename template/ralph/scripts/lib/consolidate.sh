#!/bin/bash

# Consolidation marker lives outside the run dir so it survives the archive move.
# Path: ralph/.consolidation-done-<run-id>
# This is set in ralph.sh as CONSOLIDATION_STATE_FILE and CONSOLIDATION_STATE_REL_PATH.

consolidation_needed() {
  # Only scoped runs go through consolidation; legacy mode has no archival lifecycle.
  [[ "$RUN_MODE" == "scoped" ]] || return 1

  # If a merge-back is required but not yet done, consolidation is not yet ready to run.
  if merge_back_needed && ! merge_back_done; then
    return 1
  fi

  return 0
}

consolidation_done() {
  [[ -f "$CONSOLIDATION_STATE_FILE" ]] || return 1

  grep -qx "status=done" "$CONSOLIDATION_STATE_FILE" \
    && grep -qx "run_id=$RUN_ID" "$CONSOLIDATION_STATE_FILE"
}

# Locate the archive dir of an already-archived run: `<date>-<run-id>` under
# ralph/archive/. Used when a prior attempt moved the run dir but did not get to
# the PRD markdown, so a rerun can still finish the job.
find_run_archive_dir() {
  local archive_root="$RALPH_ROOT/archive"
  local candidate

  [[ -d "$archive_root" ]] || return 0

  while IFS= read -r candidate; do
    [[ -d "$candidate" ]] || continue
    echo "$candidate"
    return 0
  done < <(find "$archive_root" -mindepth 1 -maxdepth 1 -type d \
    -name "[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-$RUN_ID" 2>/dev/null | sort -r)
}

# Move the run's source PRD markdown next to the archived run dir, so a finished
# run leaves ralph/tasks/ holding only PRDs that are still in play.
archive_run_prd_doc() {
  local archive_dir="$1"
  local prd_doc="$RALPH_ROOT/tasks/prd-$RUN_ID.md"
  local target="$archive_dir/prd-$RUN_ID.md"

  ARCHIVED_PRD_REL_PATH=""

  if [[ ! -f "$prd_doc" ]]; then
    if [[ ! -f "$target" ]]; then
      echo "Ralph consolidation: no source PRD markdown to archive at ralph/tasks/prd-$RUN_ID.md"
    fi
    return 0
  fi

  if [[ -e "$target" ]]; then
    echo "Error: Ralph consolidation PRD archive target already exists: $target" >&2
    echo "Refusing to archive ralph/tasks/prd-$RUN_ID.md; both PRD files were left in place." >&2
    return 1
  fi

  mkdir -p "$archive_dir"

  echo "Archiving source PRD: ralph/tasks/prd-$RUN_ID.md -> ralph/archive/$(basename "$archive_dir")/prd-$RUN_ID.md"
  mv "$prd_doc" "$target"
  ARCHIVED_PRD_REL_PATH="ralph/tasks/prd-$RUN_ID.md"
}

archive_consolidated_run() {
  # Archive is now a top-level sibling of runs/ (was runs/_archive/).
  local archive_root="$RALPH_ROOT/archive"
  local archive_name
  local archive_target
  local source_dir="$RUNS_ROOT/$RUN_ID"

  if [[ -d "$source_dir" ]]; then
    archive_name="$(date +%Y-%m-%d)-$RUN_ID"
    archive_target="$archive_root/$archive_name"

    if [[ -e "$archive_target" ]]; then
      echo "Error: Ralph consolidation archive target already exists: $archive_target" >&2
      echo "Refusing to archive run $RUN_ID; the active run dir and source PRD were left in place." >&2
      return 1
    fi

    mkdir -p "$archive_root"

    echo "Archiving completed run dir: ralph/runs/$RUN_ID -> ralph/archive/$archive_name"
    mv "$source_dir" "$archive_target"

    # The wrap-up markers are in-progress signals and should not be archived.
    rm -f "$archive_target/.merge-back-done"
    rm -f "$archive_target/.scaffold-cleanup-done"
  else
    echo "Ralph consolidation: run dir already archived or missing: $source_dir"
    archive_target="$(find_run_archive_dir)"

    if [[ -z "$archive_target" ]]; then
      return 0
    fi
  fi

  archive_run_prd_doc "$archive_target" || return $?

  git -C "$REPO_ROOT" add -A "ralph/runs/" "ralph/archive/" >/dev/null 2>&1 || true

  # Stage only this run's PRD markdown, never whatever else sits in ralph/tasks/.
  if [[ -n "$ARCHIVED_PRD_REL_PATH" ]]; then
    git -C "$REPO_ROOT" add -A -- "$ARCHIVED_PRD_REL_PATH" >/dev/null 2>&1 || true
  fi

  if ! git -C "$REPO_ROOT" diff --cached --quiet; then
    git -C "$REPO_ROOT" commit -m "chore(ralph): archive completed run $RUN_ID" >/dev/null
    echo "Archived run dir committed on $BASE_BRANCH."
  else
    echo "Warning: archive move produced no staged changes; nothing to commit."
  fi
}
