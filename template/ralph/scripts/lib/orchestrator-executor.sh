#!/bin/bash
# Shared Ralph child-process engine for orchestrate.sh.
#
# The caller owns scheduling and presentation. This module owns process launch,
# indexed pid/log/result state, completion-order polling, exit classification,
# and termination. It intentionally uses indexed arrays only: macOS ships Bash
# 3.2, which has neither associative arrays nor namerefs.

ORCH_EXEC_NAMES=()
ORCH_EXEC_PIDS=()
ORCH_EXEC_LOGS=()
ORCH_EXEC_STATES=()
ORCH_EXEC_RCS=()
ORCH_EXEC_RESULTS=()
ORCH_EXEC_COMPLETED=()
ORCH_EXEC_REAPED=0
ORCH_PIDS=()

orchestrator_executor_reset() {
  ORCH_EXEC_NAMES=()
  ORCH_EXEC_PIDS=()
  ORCH_EXEC_LOGS=()
  ORCH_EXEC_STATES=()
  ORCH_EXEC_RCS=()
  ORCH_EXEC_RESULTS=()
  ORCH_EXEC_COMPLETED=()
  ORCH_EXEC_REAPED=0
  ORCH_PIDS=()
}

orchestrator_executor_add() {
  local run_id="$1"

  ORCH_EXEC_NAMES+=("$run_id")
  ORCH_EXEC_PIDS+=("")
  ORCH_EXEC_LOGS+=("")
  ORCH_EXEC_STATES+=("pending")
  ORCH_EXEC_RCS+=("0")
  ORCH_EXEC_RESULTS+=("")
}

orchestrator_executor_register_child() {
  local idx="$1"
  local pid="$2"
  local log_file="$3"

  ORCH_EXEC_PIDS[$idx]="$pid"
  ORCH_EXEC_LOGS[$idx]="$log_file"
  ORCH_EXEC_STATES[$idx]="running"
  ORCH_PIDS+=("$pid")
}

# Logged launches are used by graph mode and parallel stages.
orchestrator_executor_launch_logged() {
  local idx="$1"
  local run_id log_file pid

  run_id="${ORCH_EXEC_NAMES[$idx]}"
  log_file="$RUNS_ROOT/$run_id/orchestrator-$TIMESTAMP.log"
  mkdir -p "$(dirname "$log_file")"
  echo "  -> $run_id  (log: $log_file)"

  "$RALPH_SCRIPT" --run "$run_id" --tool "$TOOL" >"$log_file" 2>&1 &
  pid=$!
  orchestrator_executor_register_child "$idx" "$pid" "$log_file"
}

# A single-run stage deliberately inherits the terminal instead of logging.
orchestrator_executor_launch_streamed() {
  local idx="$1"
  local run_id pid

  run_id="${ORCH_EXEC_NAMES[$idx]}"
  "$RALPH_SCRIPT" --run "$run_id" --tool "$TOOL" &
  pid=$!
  orchestrator_executor_register_child "$idx" "$pid" ""
}

# Reap one child and normalize its result. Always return success so callers can
# inspect the recorded exit code without `set -e` short-circuiting policy code.
orchestrator_executor_reap() {
  local idx="$1"
  local rc=0

  wait "${ORCH_EXEC_PIDS[$idx]}" || rc=$?
  ORCH_EXEC_RCS[$idx]="$rc"

  if [[ "$rc" -eq 0 ]]; then
    ORCH_EXEC_STATES[$idx]="succeeded"
    ORCH_EXEC_RESULTS[$idx]="ok"
  elif [[ "$rc" -eq "$RALPH_RATE_LIMIT_EXIT_CODE" ]]; then
    ORCH_EXEC_STATES[$idx]="failed"
    ORCH_EXEC_RESULTS[$idx]="rate-limited"
  else
    ORCH_EXEC_STATES[$idx]="failed"
    ORCH_EXEC_RESULTS[$idx]="failed"
  fi
}

# Scan in stable run order and reap every child that finished since the last
# poll. This reports fast later siblings without blocking on an earlier pid.
orchestrator_executor_poll_completed() {
  local idx=0

  ORCH_EXEC_COMPLETED=()
  ORCH_EXEC_REAPED=0

  while [[ $idx -lt ${#ORCH_EXEC_NAMES[@]} ]]; do
    if [[ "${ORCH_EXEC_STATES[$idx]}" == "running" ]] \
      && ! kill -0 "${ORCH_EXEC_PIDS[$idx]}" 2>/dev/null; then
      orchestrator_executor_reap "$idx"
      ORCH_EXEC_COMPLETED+=("$idx")
      ORCH_EXEC_REAPED=1
    fi
    idx=$((idx + 1))
  done

  # Keep the signal trap's registry limited to children that are still live.
  # A completed pid can be reused by the OS before the scheduler's next poll.
  orchestrator_executor_refresh_pids
}

orchestrator_executor_has_running() {
  local idx=0
  while [[ $idx -lt ${#ORCH_EXEC_NAMES[@]} ]]; do
    if [[ "${ORCH_EXEC_STATES[$idx]}" == "running" ]]; then
      return 0
    fi
    idx=$((idx + 1))
  done
  return 1
}

# Refresh the signal/termination registry from live executor state. Callers may
# choose when to refresh so their established stop message remains unchanged.
orchestrator_executor_refresh_pids() {
  local idx=0
  ORCH_PIDS=()
  while [[ $idx -lt ${#ORCH_EXEC_NAMES[@]} ]]; do
    if [[ "${ORCH_EXEC_STATES[$idx]}" == "running" ]]; then
      ORCH_PIDS+=("${ORCH_EXEC_PIDS[$idx]}")
    fi
    idx=$((idx + 1))
  done
}

orchestrator_executor_forget_pids() {
  ORCH_PIDS=()
}

orchestrator_executor_mark_running_stopped() {
  local idx=0
  while [[ $idx -lt ${#ORCH_EXEC_NAMES[@]} ]]; do
    if [[ "${ORCH_EXEC_STATES[$idx]}" == "running" ]]; then
      ORCH_EXEC_STATES[$idx]="stopped"
    fi
    idx=$((idx + 1))
  done
}

orchestrator_executor_clear_status_files() {
  local idx=0
  while [[ $idx -lt ${#ORCH_EXEC_NAMES[@]} ]]; do
    rm -f "$STATUS_ROOT/${ORCH_EXEC_NAMES[$idx]}.json" 2>/dev/null || true
    idx=$((idx + 1))
  done
}

orchestrator_executor_terminate() {
  if [[ ${#ORCH_PIDS[@]} -gt 0 ]]; then
    echo ""
    echo "Stopping in-flight Ralph runs: ${ORCH_PIDS[*]}" >&2
    kill -TERM "${ORCH_PIDS[@]}" 2>/dev/null || true
    wait "${ORCH_PIDS[@]}" 2>/dev/null || true
  fi
}
