#!/bin/bash

# One implementation round plus its single unblock follow-up when the story
# remains incomplete. The unblock work deliberately shares the outer ROUND.

ralph_run_story_unblock_phase() {
  local story_id="$1"
  local story_file="$2"
  local round="$3"
  local failed_tool_exit_code="$4"
  local failed_tool_saw_completion="$5"
  local failed_round_before_head="$6"
  local failed_round_after_head="$7"
  local failed_tool_diagnostic_file="$8"
  local failed_round_last_message="$9"
  local pre_unblock_structure
  local unblock_head_before
  local unblock_message
  local unblock_diagnostic_file
  local story_passed

  ralph_log_line warn "Warning: $story_id is still not marked passes=true in $PRD_FILE"

  # The unblock round may rewrite the backlog rather than the code, so capture
  # what the split looks like now. passes/notes are excluded: those move on
  # every ordinary round and say nothing about the structure.
  pre_unblock_structure=$(prd_structure_fingerprint)

  ralph_observers_update "unblocking" "$story_id" "$round"
  echo ""
  ralph_log_banner unblock "Ralph Story Unblock Round ($TOOL) - Target: $story_id"
  ralph_log_line unblock "The failed story is not retried blindly. One round decides whether it is genuinely blocked, then finishes it or restructures the backlog around it."

  UNBLOCK_PROMPT_FILE=$(mktemp)
  make_story_unblock_prompt \
    "$UNBLOCK_PROMPT_FILE" \
    "$story_id" \
    "$story_file" \
    "$round" \
    "$failed_tool_exit_code" \
    "$failed_tool_saw_completion" \
    "$failed_round_before_head" \
    "$failed_round_after_head" \
    "$failed_tool_diagnostic_file" \
    "$failed_round_last_message"

  # The failed round already moved on from its starting HEAD, so the unblock
  # round needs its own baseline for the PRD sync amend.
  unblock_head_before=$(git -C "$ACTIVE_WORKTREE" rev-parse --verify HEAD 2>/dev/null || echo "")

  DEFER_TOOL_FAILURE_STOP="true"
  run_selected_tool "$ACTIVE_WORKTREE" "$UNBLOCK_PROMPT_FILE"
  DEFER_TOOL_FAILURE_STOP="false"
  rm -f "$UNBLOCK_PROMPT_FILE"
  UNBLOCK_PROMPT_FILE=""

  unblock_message="$LAST_MESSAGE"
  if [[ -z "$unblock_message" ]]; then
    unblock_message="$OUTPUT"
  fi
  unblock_diagnostic_file="$LAST_TOOL_DIAGNOSTIC_FILE"

  sync_story_files_to_prd_after_iteration "$unblock_head_before"
  ralph_observers_update "checking" "$story_id" "$round"

  story_passed="$(prd_story_passes "$PRD_FILE" "$story_id")"

  if [[ "$story_passed" == "true" ]]; then
    ralph_observers_unblock "finished" || true
    echo ""
    ralph_log_line success "Ralph finished $story_id in the unblock round: it was unfinished, not blocked."
    # Hand back to the top of the loop rather than deciding anything here: the
    # next iteration re-derives the backlog and takes the wrap-up path itself.
    echo "Round $round complete. Continuing..."
    sleep 2
    return 0
  fi

  # A story can also leave the round still failing because the round agreed it
  # was blocked and reshaped the backlog instead. The next round starts on the
  # new split.
  if [[ "$(prd_structure_fingerprint)" != "$pre_unblock_structure" ]]; then
    RESTRUCTURES=$((RESTRUCTURES + 1))
    ralph_observers_unblock "restructured" || true
    echo ""
    ralph_log_line unblock "The unblock round judged $story_id blocked and restructured the backlog in $PRD_REL_PATH."
    ralph_log_line unblock "Stories now: $(prd_story_ids_summary "$PRD_FILE")"
    if [[ "$RESTRUCTURES" -le "$MAX_RESTRUCTURES" ]]; then
      ralph_log_line unblock "Restructure $RESTRUCTURES of $MAX_RESTRUCTURES for this run. Continuing on the new split..."
      sleep 2
      return 0
    fi

    ralph_observers_stop || true
    echo ""
    ralph_log_line unblock "================= Ralph Story Unblock Round ================="
    printf '%s\n' "$unblock_message"
    ralph_log_line unblock "============================================================="
    ralph_log_line error "Ralph restructured the backlog $RESTRUCTURES times in this run (limit $MAX_RESTRUCTURES) and stories are still failing."
    ralph_log_line error "A split that keeps needing repair is a PRD problem. Review $PRD_REL_PATH and the reports above before rerunning."
    notify_ralph_needs_attention "backlog restructured $RESTRUCTURES times without the run progressing"
    exit 1
  fi

  ralph_observers_unblock "stopped" || true
  # Release the pinned row before printing the durable handoff so the report
  # remains readable at the user's shell prompt.
  ralph_observers_stop || true
  echo ""
  ralph_log_line unblock "================= Ralph Story Unblock Round ================="
  if [[ -n "$unblock_message" ]]; then
    printf '%s\n' "$unblock_message"
  else
    echo "The unblock agent produced no final report (exit $LAST_TOOL_EXIT_CODE)."
  fi
  # Only a failed CLI leaves a diagnostic file behind, so each of these lines
  # appears exactly when that round's tool itself went wrong.
  if [[ -n "$unblock_diagnostic_file" ]]; then
    echo "The unblock round's raw events are available at: $unblock_diagnostic_file"
  fi
  if [[ -n "$failed_tool_diagnostic_file" ]]; then
    echo "The failed implementation round's raw events are available at: $failed_tool_diagnostic_file"
  fi
  ralph_log_line unblock "============================================================="
  ralph_log_line error "Ralph stopped: the unblock round neither finished $story_id nor restructured the backlog around it. Review the report above before rerunning."
  notify_ralph_needs_attention "story $story_id still failing after the unblock round"
  exit 1
}

ralph_run_story_phase() {
  local story_id="$1"
  local round="$2"
  local current_story_file
  local pre_iteration_head
  local failed_round_last_message
  local failed_round_tool_exit_code
  local failed_round_saw_completion
  local failed_round_diagnostic_file
  local failed_round_after_head
  local story_passed
  local all_complete

  echo ""
  ralph_log_banner story "Ralph Round $round ($TOOL) - Target: $story_id"

  current_story_file="$(story_file_path "$story_id")"
  if [[ ! -f "$current_story_file" ]]; then
    ralph_log_line error "Error: Missing current story file: $current_story_file"
    exit 1
  fi

  ITERATION_PROMPT_FILE=$(mktemp)
  make_prompt_with_story_context "$ACTIVE_CONTEXT_PROMPT_FILE" "$ITERATION_PROMPT_FILE" "$story_id" "$current_story_file"

  pre_iteration_head=$(git -C "$ACTIVE_WORKTREE" rev-parse --verify HEAD 2>/dev/null || echo "")

  # A story round is never retried blindly. Even when the underlying CLI fails,
  # let the controller reach the file-based story check and unblock round.
  DEFER_TOOL_FAILURE_STOP="true"
  run_selected_tool "$ACTIVE_WORKTREE" "$ITERATION_PROMPT_FILE"
  DEFER_TOOL_FAILURE_STOP="false"
  rm -f "$ITERATION_PROMPT_FILE"
  ITERATION_PROMPT_FILE=""

  failed_round_last_message="$LAST_MESSAGE"
  if [[ -z "$failed_round_last_message" ]]; then
    failed_round_last_message="$OUTPUT"
  fi
  failed_round_tool_exit_code="$LAST_TOOL_EXIT_CODE"
  failed_round_saw_completion="$LAST_TOOL_SAW_COMPLETION"
  failed_round_diagnostic_file="$LAST_TOOL_DIAGNOSTIC_FILE"

  sync_story_files_to_prd_after_iteration "$pre_iteration_head"
  failed_round_after_head=$(git -C "$ACTIVE_WORKTREE" rev-parse --verify HEAD 2>/dev/null || echo "")
  ralph_observers_update "checking" "$story_id" "$round"

  story_passed="$(prd_story_passes "$PRD_FILE" "$story_id")"
  all_complete="$(prd_all_stories_complete "$PRD_FILE")"

  if [[ "$story_passed" != "true" ]]; then
    ralph_run_story_unblock_phase \
      "$story_id" \
      "$current_story_file" \
      "$round" \
      "$failed_round_tool_exit_code" \
      "$failed_round_saw_completion" \
      "$pre_iteration_head" \
      "$failed_round_after_head" \
      "$failed_round_diagnostic_file" \
      "$failed_round_last_message"
    return 0
  fi

  if [[ "$all_complete" == "true" ]]; then
    ralph_transition_after_story_completion "$round"
  fi

  if [[ "$TOOL" == "codex" && "$LAST_MESSAGE" == *"<promise>COMPLETE</promise>"* ]]; then
    ralph_log_line warn "Warning: Codex reported COMPLETE, but Ralph still has remaining work. Continuing."
  elif echo "$OUTPUT" | grep -q "<promise>COMPLETE</promise>"; then
    ralph_log_line warn "Warning: Tool reported COMPLETE, but Ralph still has remaining work. Continuing."
  fi

  echo "Round $round complete. Continuing..."
  sleep 2
  return 0
}
