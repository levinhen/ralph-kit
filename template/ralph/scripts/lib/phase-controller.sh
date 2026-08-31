#!/bin/bash

# The single owner of phase selection and outer ROUND progression. Phase
# handlers perform work; they do not independently decide which phase follows.

ralph_phase_controller_init() {
  # Story rounds are self-limiting: an incomplete story gets one unblock round.
  # Marker-driven wrap-up rounds need explicit retry budgets.
  MAX_CLEANUP_ROUNDS="${RALPH_MAX_CLEANUP_ROUNDS:-3}"
  MAX_FINALIZE_ROUNDS="${RALPH_MAX_FINALIZE_ROUNDS:-3}"
  MAX_MERGE_BACK_ROUNDS="${RALPH_MAX_MERGE_BACK_ROUNDS:-3}"
  MAX_CONSOLIDATION_ROUNDS="${RALPH_MAX_CONSOLIDATION_ROUNDS:-3}"
  CLEANUP_ROUNDS=0
  FINALIZE_ROUNDS=0
  MERGE_BACK_ROUNDS=0
  CONSOLIDATION_ROUNDS=0

  # A restructure hands control back to the loop. Bound repeated repairs across
  # the whole run rather than resetting the count for each story.
  MAX_RESTRUCTURES="${RALPH_MAX_RESTRUCTURES:-2}"
  RESTRUCTURES=0

  # Counts every outer loop round, including wrap-up rounds. The unblock
  # follow-up remains inside its story round and therefore shares this number.
  ROUND=0
  CURRENT_STORY_ID=""
  RALPH_PHASE=""
}

wrap_up_budget_exhausted() {
  local phase="$1"
  local limit="$2"

  ralph_observers_stop || true
  echo ""
  ralph_log_line error "Ralph ran the $phase round $limit times without it completing."
  ralph_log_line error "Check $PROGRESS_FILE and the output above before rerunning."
  notify_ralph_needs_attention "$phase did not complete after $limit rounds"
  exit 1
}

ralph_begin_round() {
  ROUND=$((ROUND + 1))

  # An unblock round can add stories to the PRD. Back-fill their story files
  # before syncing back, so the next story is ordinary when selected.
  initialize_story_files
  sync_story_files_to_prd

  CURRENT_STORY_ID="$(prd_next_incomplete_story_id "$PRD_FILE")"

  if [[ -n "$CURRENT_STORY_ID" ]]; then
    ralph_observers_update "working" "$CURRENT_STORY_ID" "$ROUND"
    # A story can add new scaffolding after a prior wrap-up attempt. Clear all
    # downstream proof markers and reset their retry budgets.
    rm -f "$SCAFFOLD_CLEANUP_STATE_FILE"
    rm -f "$MERGE_BACK_STATE_FILE"
    [[ -n "$CONSOLIDATION_STATE_FILE" ]] && rm -f "$CONSOLIDATION_STATE_FILE"
    CLEANUP_ROUNDS=0
    FINALIZE_ROUNDS=0
    MERGE_BACK_ROUNDS=0
    CONSOLIDATION_ROUNDS=0
  fi
}

# Select exactly one phase. Passing an empty story id intentionally skips the
# story branch; the story handler uses that after it has just completed the last
# story so it consults the same wrap-up ordering as the top of the loop.
ralph_select_phase() {
  local story_id="${1:-}"

  if [[ -n "$story_id" ]]; then
    RALPH_PHASE="story"
  elif scaffold_cleanup_needed && ! scaffold_cleanup_done; then
    RALPH_PHASE="cleanup"
  elif merge_back_needed && ! merge_back_done; then
    RALPH_PHASE="merge-back"
  elif consolidation_needed && ! consolidation_done; then
    RALPH_PHASE="consolidation"
  else
    RALPH_PHASE="complete"
  fi
}

# Preserve the existing story-round timing: announce a pending wrap-up and let
# it start on the next ROUND, but finish immediately in this ROUND when there is
# no wrap-up work. The selector above remains the only source of that decision.
ralph_transition_after_story_completion() {
  local round="$1"

  ralph_select_phase ""
  case "$RALPH_PHASE" in
    cleanup)
      ralph_log_line success "All stories are marked complete in $PRD_FILE. The next round will strip the run's per-story scaffolding."
      ;;
    merge-back)
      ralph_log_line success "All stories are marked complete in $PRD_FILE. The next round will run the dedicated merge-back round."
      ;;
    consolidation)
      ralph_log_line success "All stories are marked complete in $PRD_FILE. The next round will run the dedicated consolidation round."
      ;;
    complete)
      ralph_finish_after_story "$round"
      ;;
  esac
}

ralph_phase_loop() {
  while true; do
    ralph_begin_round
    ralph_select_phase "$CURRENT_STORY_ID"

    case "$RALPH_PHASE" in
      story)
        ralph_run_story_phase "$CURRENT_STORY_ID" "$ROUND"
        ;;
      cleanup)
        ralph_run_cleanup_phase "$ROUND"
        ;;
      merge-back)
        ralph_run_merge_back_phase "$ROUND"
        ;;
      consolidation)
        ralph_run_consolidation_phase "$ROUND"
        ;;
      complete)
        ralph_finish_after_wrapup "$ROUND"
        ;;
      *)
        echo "Error: Ralph selected unknown phase '$RALPH_PHASE'." >&2
        exit 1
        ;;
    esac
  done
}
