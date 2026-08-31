#!/bin/bash
# Manual stage-plan parsing, presentation, confirmation, and execution for
# orchestrate.sh. Child-process state is shared with graph mode through
# orchestrator-executor.sh.

PLAN_STAGES=()
SEEN_TOKENS=":"
UNSCHEDULED=()

stage_read_plan() {
  if [[ -z "$PLAN_INPUT" ]]; then
    if [[ ! -t 0 ]]; then
      echo "Error: No plan provided and stdin is not interactive." >&2
      echo "Pass --plan \"1 > 2,3 > 4\" or run from a terminal." >&2
      exit 1
    fi
    echo "Plan syntax: ',' = parallel, '>' = serial. Example: 1 > 2,3 > 4"
    read -r -p "Plan> " PLAN_INPUT
  fi
}

stage_parse_plan() {
  local plan_stripped old_ifs raw stage_runs tok idx
  local raw_stages=() raw_tokens=()

  plan_stripped="${PLAN_INPUT//[[:space:]]/}"

  if [[ -z "$plan_stripped" ]]; then
    echo "Error: Empty plan." >&2
    exit 1
  fi

  if [[ ! "$plan_stripped" =~ ^[0-9,\>]+$ ]]; then
    echo "Error: Plan contains invalid characters. Allowed: digits, ',', '>'." >&2
    exit 1
  fi

  # Reject leading/trailing/adjacent separators up front (read drops trailing
  # empty fields silently otherwise).
  case "$plan_stripped" in
    ,*|*,|\>*|*\>)
      echo "Error: Plan must not start or end with ',' or '>'." >&2
      exit 1
      ;;
  esac
  if [[ "$plan_stripped" == *,,* || "$plan_stripped" == *\>\>* \
     || "$plan_stripped" == *,\>* || "$plan_stripped" == *\>,* ]]; then
    echo "Error: Plan has adjacent separators (',,' / '>>' / ',>' / '>,')." >&2
    exit 1
  fi

  PLAN_STAGES=()
  SEEN_TOKENS=":"

  old_ifs="$IFS"
  IFS='>' read -ra raw_stages <<< "$plan_stripped"
  IFS="$old_ifs"

  for raw in "${raw_stages[@]}"; do
    if [[ -z "$raw" ]]; then
      echo "Error: Empty stage in plan (check for consecutive '>' or stray '>')." >&2
      exit 1
    fi

    raw_tokens=()
    IFS=',' read -ra raw_tokens <<< "$raw"
    IFS="$old_ifs"

    stage_runs=""
    for tok in "${raw_tokens[@]}"; do
      if [[ -z "$tok" ]]; then
        echo "Error: Empty token in plan (check for consecutive ',' or stray ',')." >&2
        exit 1
      fi
      if [[ ! "$tok" =~ ^[0-9]+$ ]]; then
        echo "Error: Non-numeric token '$tok' in plan." >&2
        exit 1
      fi

      idx=$((tok - 1))
      if [[ $idx -lt 0 || $idx -ge $TOTAL_RUNS ]]; then
        echo "Error: Number $tok is out of range (1-$TOTAL_RUNS)." >&2
        exit 1
      fi

      case "$SEEN_TOKENS" in
        *":$tok:"*)
          echo "Error: Run number $tok appears more than once in plan." >&2
          exit 1
          ;;
      esac
      SEEN_TOKENS="$SEEN_TOKENS$tok:"

      if [[ -z "$stage_runs" ]]; then
        stage_runs="${INCOMPLETE_RUNS[$idx]}"
      else
        stage_runs="$stage_runs ${INCOMPLETE_RUNS[$idx]}"
      fi
    done

    PLAN_STAGES+=("$stage_runs")
  done
}

stage_show_plan() {
  local i=0 j line num r
  local stage_runs=()

  echo ""
  echo "Resolved plan:"
  while [[ $i -lt ${#PLAN_STAGES[@]} ]]; do
    stage_runs=()
    read -ra stage_runs <<< "${PLAN_STAGES[$i]}"
    if [[ ${#stage_runs[@]} -eq 1 ]]; then
      printf "  Stage %d:  %s\n" "$((i + 1))" "${stage_runs[0]}"
    else
      line=""
      j=0
      while [[ $j -lt ${#stage_runs[@]} ]]; do
        if [[ -z "$line" ]]; then
          line="${stage_runs[$j]}"
        else
          line="$line  ‖  ${stage_runs[$j]}"
        fi
        j=$((j + 1))
      done
      printf "  Stage %d:  %s\n" "$((i + 1))" "$line"
    fi
    i=$((i + 1))
  done

  # Unscheduled runs will not be touched.
  UNSCHEDULED=()
  i=0
  while [[ $i -lt $TOTAL_RUNS ]]; do
    num=$((i + 1))
    case "$SEEN_TOKENS" in
      *":$num:"*) ;;
      *) UNSCHEDULED+=("${INCOMPLETE_RUNS[$i]}") ;;
    esac
    i=$((i + 1))
  done

  if [[ ${#UNSCHEDULED[@]} -gt 0 ]]; then
    echo ""
    echo "Unscheduled (will be skipped):"
    for r in "${UNSCHEDULED[@]}"; do
      echo "  - $r"
    done
  fi
}

stage_confirm() {
  if [[ "$DRY_RUN" == "true" ]]; then
    echo ""
    echo "Dry run: not executing any Ralph runs."
    exit 0
  fi

  if [[ -t 0 ]]; then
    echo ""
    read -r -p "Confirm? [y/N] " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
      echo "Aborted."
      exit 1
    fi
  else
    echo ""
    echo "Plan supplied non-interactively; proceeding without confirmation."
  fi
}

# One board frame for the runs of the current parallel stage. A stage has no
# pending or blocked runs - everything in it launched together - so the frame is
# simply every sibling in launch order.
stage_render_board() {
  local idx=0 note
  local running=0 succeeded=0 failed=0

  ralph_board_begin_frame

  while [[ $idx -lt ${#ORCH_EXEC_NAMES[@]} ]]; do
    case "${ORCH_EXEC_STATES[$idx]}" in
      running) running=$((running + 1)) ;;
      succeeded) succeeded=$((succeeded + 1)) ;;
      failed | stopped) failed=$((failed + 1)) ;;
    esac
    idx=$((idx + 1))
  done

  idx=0
  while [[ $idx -lt ${#ORCH_EXEC_NAMES[@]} ]]; do
    note=""
    if [[ "${ORCH_EXEC_STATES[$idx]}" == "failed" ]]; then
      note="exit ${ORCH_EXEC_RCS[$idx]:-?}"
    fi
    ralph_board_row "${ORCH_EXEC_NAMES[$idx]}" "${ORCH_EXEC_STATES[$idx]}" "$note"
    idx=$((idx + 1))
  done

  ralph_board_end_frame "$running" "$succeeded" "$failed"
}

execute_stage() {
  local stage_num="$1"
  shift
  local runs=("$@")
  local run_id idx=0 r rc

  orchestrator_executor_reset
  for run_id in "${runs[@]}"; do
    orchestrator_executor_add "$run_id"
  done

  echo ""
  echo "==============================================================="
  if [[ ${#runs[@]} -eq 1 ]]; then
    echo "  Stage $stage_num: ${runs[0]}"
  else
    echo "  Stage $stage_num: parallel (${#runs[@]} runs)"
    for r in "${runs[@]}"; do
      echo "    - $r"
    done
  fi
  echo "==============================================================="

  if [[ ${#runs[@]} -eq 1 ]]; then
    orchestrator_executor_launch_streamed 0
    orchestrator_executor_reap 0
    orchestrator_executor_forget_pids
    rc="${ORCH_EXEC_RCS[0]}"
    if [[ "$rc" -eq 0 ]]; then
      echo "[stage $stage_num] ${runs[0]}: ok"
      return 0
    fi
    if [[ "$rc" -eq "$RALPH_RATE_LIMIT_EXIT_CODE" ]]; then
      echo "[stage $stage_num] ${runs[0]}: rate-limited (exit $rc)" >&2
      return "$RALPH_RATE_LIMIT_EXIT_CODE"
    fi
    echo "[stage $stage_num] ${runs[0]}: FAILED (exit $rc)" >&2
    return "$rc"
  fi

  # Parallel: redirect each run to its own log file. Nothing they print reaches
  # this terminal from here on, so the board is what keeps the stage legible.
  orchestrator_executor_clear_status_files
  ralph_board_start "$STATUS_ROOT" "${#runs[@]}"
  while [[ $idx -lt ${#ORCH_EXEC_NAMES[@]} ]]; do
    orchestrator_executor_launch_logged "$idx"
    idx=$((idx + 1))
  done

  local stage_failed=0 stage_rate_limited=0 completed_idx

  # Reap in completion order rather than launch order. Waiting on pids[0] first
  # would hide a later sibling's failure until every earlier run has finished,
  # so the failure is recorded the moment the run exits (after its own unblock
  # round). Siblings still run to completion; only the next stage is withheld.
  while orchestrator_executor_has_running; do
    orchestrator_executor_poll_completed
    for completed_idx in "${ORCH_EXEC_COMPLETED[@]}"; do
      case "${ORCH_EXEC_RESULTS[$completed_idx]}" in
        ok)
          echo "  [stage $stage_num] ${ORCH_EXEC_NAMES[$completed_idx]}: ok"
          ;;
        rate-limited)
          echo "  [stage $stage_num] ${ORCH_EXEC_NAMES[$completed_idx]}: rate-limited (exit ${ORCH_EXEC_RCS[$completed_idx]}, see ${ORCH_EXEC_LOGS[$completed_idx]})" >&2
          stage_rate_limited=1
          stage_failed=1
          ;;
        failed)
          echo "  [stage $stage_num] ${ORCH_EXEC_NAMES[$completed_idx]}: FAILED (exit ${ORCH_EXEC_RCS[$completed_idx]}, see ${ORCH_EXEC_LOGS[$completed_idx]})" >&2
          stage_failed=1
          ;;
      esac
    done

    # A rate limit is the one failure that cuts the stage short: the remaining
    # runs would only burn requests against the same exhausted quota.
    if [[ "$stage_rate_limited" -eq 1 ]]; then
      ralph_board_stop
      orchestrator_executor_refresh_pids
      orchestrator_executor_terminate
      orchestrator_executor_mark_running_stopped
      orchestrator_executor_forget_pids
      break
    fi

    stage_render_board
    if orchestrator_executor_has_running && [[ "$ORCH_EXEC_REAPED" -eq 0 ]]; then
      sleep 1
    fi
  done

  ralph_board_stop
  orchestrator_executor_forget_pids
  if [[ "$stage_rate_limited" -eq 1 ]]; then
    return "$RALPH_RATE_LIMIT_EXIT_CODE"
  fi
  return "$stage_failed"
}

stage_execute_plan() {
  local start_time end_time i=0 rc
  local stage_runs=()

  # Disable strict mode for the loop so we can react to per-stage failures.
  set +e

  start_time=$(date +%s)
  while [[ $i -lt ${#PLAN_STAGES[@]} ]]; do
    stage_runs=()
    read -ra stage_runs <<< "${PLAN_STAGES[$i]}"
    execute_stage "$((i + 1))" "${stage_runs[@]}"
    rc=$?
    if [[ $rc -ne 0 ]]; then
      end_time=$(date +%s)
      echo ""
      if [[ "$rc" -eq "$RALPH_RATE_LIMIT_EXIT_CODE" ]]; then
        echo "Stage $((i + 1)) detected a 429/rate-limit response. Stopping orchestrator (later stages skipped)." >&2
        echo "Total elapsed: $((end_time - start_time))s"
        exit "$RALPH_RATE_LIMIT_EXIT_CODE"
      fi
      echo "Stage $((i + 1)) had failures. Stopping orchestrator (later stages skipped)." >&2
      echo "Total elapsed: $((end_time - start_time))s"
      exit "$rc"
    fi
    i=$((i + 1))
  done

  end_time=$(date +%s)
  echo ""
  echo "All ${#PLAN_STAGES[@]} stage(s) completed successfully."
  echo "Total elapsed: $((end_time - start_time))s"
  exit 0
}

stage_main() {
  stage_read_plan
  stage_parse_plan
  stage_show_plan
  stage_confirm
  stage_execute_plan
}
