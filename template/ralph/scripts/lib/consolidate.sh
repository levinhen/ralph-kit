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

archive_consolidated_run() {
  # Archive is now a top-level sibling of runs/ (was runs/_archive/).
  local archive_root="$RALPH_ROOT/archive"
  local archive_name
  local archive_target
  local source_dir="$RUNS_ROOT/$RUN_ID"

  if [[ ! -d "$source_dir" ]]; then
    echo "Ralph consolidation: run dir already archived or missing: $source_dir"
    return 0
  fi

  archive_name="$(date +%Y-%m-%d)-$RUN_ID"
  archive_target="$archive_root/$archive_name"

  if [[ -e "$archive_target" ]]; then
    echo "Ralph consolidation: archive target already exists, skipping mv: $archive_target"
    return 0
  fi

  mkdir -p "$archive_root"

  echo "Archiving completed run dir: ralph/runs/$RUN_ID -> ralph/archive/$archive_name"
  mv "$source_dir" "$archive_target"

  # The .merge-back-done marker is an in-progress signal and should not be archived.
  rm -f "$archive_target/.merge-back-done"

  git -C "$REPO_ROOT" add -A "ralph/runs/" "ralph/archive/" >/dev/null 2>&1 || true

  if ! git -C "$REPO_ROOT" diff --cached --quiet; then
    git -C "$REPO_ROOT" commit -m "chore(ralph): archive completed run $RUN_ID" >/dev/null
    echo "Archived run dir committed on $BASE_BRANCH."
  else
    echo "Warning: archive move produced no staged changes; nothing to commit."
  fi
}
