#!/bin/bash

# Dedicated wrap-up phase handlers. Each invocation consumes the current outer
# ROUND, performs at most one agent round, and either exits or returns control to
# the phase loop for the next ROUND.

ralph_run_cleanup_phase() {
  local round="$1"
  local cleanup_append_command
  local cleanup_story_list

  CLEANUP_ROUNDS=$((CLEANUP_ROUNDS + 1))
  if [[ "$CLEANUP_ROUNDS" -gt "$MAX_CLEANUP_ROUNDS" ]]; then
    wrap_up_budget_exhausted "scaffold cleanup" "$MAX_CLEANUP_ROUNDS"
  fi

  ralph_observers_update "cleanup" "" "$round"
  echo ""
  ralph_log_banner merge "Ralph Scaffold Cleanup Round ($TOOL) - ${TARGET_BRANCH:-$BASE_BRANCH}"
  ralph_log_line merge "Every story passes. This round removes the per-story scaffolding before anything merges back; it may not touch a criterion or a passes flag."

  if [[ "$RUN_MODE" == "scoped" ]]; then
    cleanup_append_command="bash ralph/scripts/append-progress-json.sh --run $RUN_ID --story SCAFFOLD-CLEANUP --record path/to/progress-record.json"
  else
    cleanup_append_command="bash ralph/scripts/append-progress-json.sh --legacy --story SCAFFOLD-CLEANUP --record path/to/progress-record.json"
  fi
  # The story list is the round's index of what to look for: scaffolding is
  # named after the story that needed it far more often than not.
  cleanup_story_list="$(prd_cleanup_story_list "$PRD_FILE")"

  CLEANUP_PROMPT_FILE=$(mktemp)
  make_prompt_with_run_context "$TOOL_PROMPT_FILE" "$CLEANUP_PROMPT_FILE"
  printf "\n\n" >> "$CLEANUP_PROMPT_FILE"
  cat "$CLEANUP_SCAFFOLD_PROMPT_FILE_TEMPLATE" >> "$CLEANUP_PROMPT_FILE"
  printf "\n\n" >> "$CLEANUP_PROMPT_FILE"
  cat <<EOF >> "$CLEANUP_PROMPT_FILE"

## Scaffold Cleanup Context

- Run ID: \`$RUN_ID_LABEL\`
- Ralph branch: \`${TARGET_BRANCH:-$BASE_BRANCH}\`
- Ralph worktree (do all work here): \`$ACTIVE_WORKTREE\`
- Base commit this run started from: \`$BASE_SHA\`
- Run PRD path: \`$PRD_REL_PATH\`
- Run story files: \`$STORIES_REL_DIR\`
- Run progress dir: \`$PROGRESS_REL_DIR\`
- Append this round's progress record with:
  \`$cleanup_append_command\`
- Cleanup marker (write this last, do NOT commit it): \`$SCAFFOLD_CLEANUP_STATE_FILE\`

Stories completed in this run:

$cleanup_story_list
EOF

  run_selected_tool "$ACTIVE_WORKTREE" "$CLEANUP_PROMPT_FILE"
  rm -f "$CLEANUP_PROMPT_FILE"
  CLEANUP_PROMPT_FILE=""

  if scaffold_cleanup_done; then
    echo ""
    if merge_back_needed; then
      ralph_log_line success "Ralph finished the scaffold cleanup round. Merge-back next."
    else
      ralph_log_line success "Ralph finished the scaffold cleanup round."
    fi
    sleep 2
    return 0
  fi

  if [[ "$TOOL" == "codex" && "$LAST_MESSAGE" == *"<promise>COMPLETE</promise>"* ]]; then
    ralph_log_line warn "Warning: Codex reported COMPLETE, but the scaffold cleanup marker was not written. Continuing."
  elif echo "$OUTPUT" | grep -q "<promise>COMPLETE</promise>"; then
    ralph_log_line warn "Warning: Tool reported COMPLETE, but the scaffold cleanup marker was not written. Continuing."
  fi

  echo "Scaffold cleanup round complete (marker not yet written). Continuing..."
  sleep 2
  return 0
}

ralph_run_merge_back_phase() {
  local round="$1"

  ralph_observers_update "merge-back" "" "$round"
  echo ""
  ralph_log_banner merge "Ralph Merge-Back Round ($TOOL) - $TARGET_BRANCH -> $BASE_BRANCH"

  if ! target_worktree_clean_for_merge; then
    FINALIZE_ROUNDS=$((FINALIZE_ROUNDS + 1))
    if [[ "$FINALIZE_ROUNDS" -gt "$MAX_FINALIZE_ROUNDS" ]]; then
      wrap_up_budget_exhausted "worktree finalization" "$MAX_FINALIZE_ROUNDS"
    fi
    ralph_observers_update "finalizing" "" "$round"
    if run_target_worktree_finalization; then
      ralph_log_line success "Ralph target worktree is clean. The next round will start merge-back."
    fi
    sleep 2
    return 0
  fi

  if [[ -z "$MERGE_LOCK_DIR" ]]; then
    MERGE_LOCK_DIR="$LOCK_ROOT/merge-$(sanitize_branch_name "$BASE_BRANCH").lock"
    acquire_dir_lock "$MERGE_LOCK_DIR" "merge-back for $BASE_BRANCH"
  fi

  if run_git_merge_back; then
    echo ""
    ralph_log_line success "Ralph merged $TARGET_BRANCH into $BASE_BRANCH. Consolidation round next."
    sleep 2
    return 0
  fi

  MERGE_BACK_ROUNDS=$((MERGE_BACK_ROUNDS + 1))
  if [[ "$MERGE_BACK_ROUNDS" -gt "$MAX_MERGE_BACK_ROUNDS" ]]; then
    wrap_up_budget_exhausted "merge-back" "$MAX_MERGE_BACK_ROUNDS"
  fi

  MERGE_PROMPT_FILE=$(mktemp)
  make_prompt_with_run_context "$TOOL_PROMPT_FILE" "$MERGE_PROMPT_FILE"
  printf "\n\n" >> "$MERGE_PROMPT_FILE"
  cat "$MERGE_BACK_PROMPT_FILE" >> "$MERGE_PROMPT_FILE"
  printf "\n\n" >> "$MERGE_PROMPT_FILE"
  cat <<EOF >> "$MERGE_PROMPT_FILE"

## Merge-Back Context

- Run ID: \`$RUN_ID_LABEL\`
- Base branch: \`$BASE_BRANCH\`
- Ralph branch: \`$TARGET_BRANCH\`
- Ralph worktree: \`$ACTIVE_WORKTREE\`
- Base repo root: \`$REPO_ROOT\`
- Base branch progress log: \`$ROOT_PROGRESS_FILE\`
- Run-scoped PRD path: \`$PRD_REL_PATH\`
- Run-scoped progress path: \`$PROGRESS_REL_PATH\`
- Merge completion marker: \`$MERGE_BACK_STATE_FILE\`
EOF

  run_selected_tool "$REPO_ROOT" "$MERGE_PROMPT_FILE"
  rm -f "$MERGE_PROMPT_FILE"
  MERGE_PROMPT_FILE=""

  if merge_back_done; then
    echo ""
    ralph_log_line success "Ralph merged $TARGET_BRANCH into $BASE_BRANCH. Consolidation round next."
    sleep 2
    return 0
  fi

  if [[ "$TOOL" == "codex" && "$LAST_MESSAGE" == *"<promise>COMPLETE</promise>"* ]]; then
    ralph_log_line warn "Warning: Codex reported COMPLETE, but merge-back marker was not written. Continuing."
  elif echo "$OUTPUT" | grep -q "<promise>COMPLETE</promise>"; then
    ralph_log_line warn "Warning: Tool reported COMPLETE, but merge-back marker was not written. Continuing."
  fi

  echo "Merge-back round complete. Continuing..."
  sleep 2
  return 0
}

ralph_run_consolidation_phase() {
  local round="$1"

  CONSOLIDATION_ROUNDS=$((CONSOLIDATION_ROUNDS + 1))
  if [[ "$CONSOLIDATION_ROUNDS" -gt "$MAX_CONSOLIDATION_ROUNDS" ]]; then
    wrap_up_budget_exhausted "consolidation" "$MAX_CONSOLIDATION_ROUNDS"
  fi

  ralph_observers_update "consolidating" "" "$round"
  echo ""
  ralph_log_banner consolidate "Ralph Consolidation Round ($TOOL) - $RUN_ID -> design-ledger"

  CONSOLIDATE_PROMPT_FILE=$(mktemp)
  make_prompt_with_run_context "$TOOL_PROMPT_FILE" "$CONSOLIDATE_PROMPT_FILE"
  printf "\n\n" >> "$CONSOLIDATE_PROMPT_FILE"
  cat "$CONSOLIDATE_PROMPT_FILE_TEMPLATE" >> "$CONSOLIDATE_PROMPT_FILE"
  printf "\n\n" >> "$CONSOLIDATE_PROMPT_FILE"
  cat <<EOF >> "$CONSOLIDATE_PROMPT_FILE"

## Ralph Consolidation Context

- Run ID: \`$RUN_ID_LABEL\`
- Base branch: \`$BASE_BRANCH\`
- Base repo root: \`$REPO_ROOT\`
- Run-scoped PRD path: \`$PRD_REL_PATH\`
- Run-scoped story dir: \`$STORIES_REL_DIR\`
- Run-scoped progress dir: \`$PROGRESS_REL_DIR\`
- Source PRD markdown (if present): \`ralph/tasks/prd-$RUN_ID.md\`
- Design ledger root: \`docs/design-ledger/\` (create the directory if missing)
- Consolidation marker path (write this last, do NOT commit it): \`$CONSOLIDATION_STATE_REL_PATH\`

After consolidation, \`ralph.sh\` will mechanically move \`ralph/runs/$RUN_ID/\` to \`ralph/archive/<date>-$RUN_ID/\`, move \`ralph/tasks/prd-$RUN_ID.md\` into that same archive dir, and create a separate archive commit. Do not do either move yourself — leave the source PRD in \`ralph/tasks/\` with its updated frontmatter.
EOF

  run_selected_tool "$REPO_ROOT" "$CONSOLIDATE_PROMPT_FILE"
  rm -f "$CONSOLIDATE_PROMPT_FILE"
  CONSOLIDATE_PROMPT_FILE=""

  if consolidation_done; then
    ralph_observers_update "complete" "" "$round"
    archive_consolidated_run
    echo ""
    if merge_back_needed; then
      ralph_log_line success "Ralph completed merge-back + consolidation for run $RUN_ID."
    else
      ralph_log_line success "Ralph completed consolidation for run $RUN_ID."
    fi
    notify_ralph_merged
    exit 0
  fi

  if [[ "$TOOL" == "codex" && "$LAST_MESSAGE" == *"<promise>COMPLETE</promise>"* ]]; then
    ralph_log_line warn "Warning: Codex reported COMPLETE, but consolidation marker was not written. Continuing."
  elif echo "$OUTPUT" | grep -q "<promise>COMPLETE</promise>"; then
    ralph_log_line warn "Warning: Tool reported COMPLETE, but consolidation marker was not written. Continuing."
  fi

  echo "Consolidation round complete (marker not yet written). Continuing..."
  sleep 2
  return 0
}

ralph_finish_after_wrapup() {
  local round="$1"

  if [[ "$RUN_MODE" == "scoped" ]] && consolidation_done; then
    archive_consolidated_run
  fi

  ralph_observers_update "complete" "" "$round"
  echo ""
  ralph_log_line success "Ralph completed all tasks!"
  ralph_log_line success "All stories in $PRD_FILE already have passes=true"
  notify_ralph_stories_completed
  exit 0
}

ralph_finish_after_story() {
  local round="$1"

  ralph_observers_update "complete" "" "$round"
  echo ""
  ralph_log_line success "Ralph completed all tasks!"
  ralph_log_line success "Completed at round $round"
  notify_ralph_stories_completed
  exit 0
}
