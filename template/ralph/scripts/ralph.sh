#!/bin/bash
# Ralph Wiggum - Long-running AI agent loop
# Usage: ./ralph.sh [--run run_id|--legacy] [--tool claude|codex|pi]

set -e

# Parse arguments
TOOL="${RALPH_TOOL:-codex}"
RUN_ID="${RALPH_RUN_ID:-}"
USE_LEGACY="false"
RALPH_NOTIFY="${RALPH_NOTIFY:-1}"
RALPH_NOTIFY_SOUND="${RALPH_NOTIFY_SOUND:-1}"
RALPH_RATE_LIMIT_EXIT_CODE=75
RALPH_TOOL_TIMEOUT_EXIT_CODE=124

while [[ $# -gt 0 ]]; do
  case $1 in
    --tool)
      TOOL="$2"
      shift 2
      ;;
    --tool=*)
      TOOL="${1#*=}"
      shift
      ;;
    --run)
      RUN_ID="$2"
      shift 2
      ;;
    --run=*)
      RUN_ID="${1#*=}"
      shift
      ;;
    --legacy)
      USE_LEGACY="true"
      shift
      ;;
    *)
      # Ralph used to take a max_iterations budget here, back when a failed
      # story was retried on the next pass. Failures now go through the
      # unblock round instead, so the number no longer bounds anything a caller
      # would want bounded - it would only cap how many stories a run can
      # finish. Accept and ignore it so existing wrappers keep working.
      if [[ "$1" =~ ^[0-9]+$ ]]; then
        echo "Warning: the max_iterations argument ('$1') is obsolete and ignored."
      fi
      shift
      ;;
  esac
done

# Establish repo/ralph/run/worktree/status/prompt roots before loading the
# remaining libraries. Both modules locate themselves and perform no writes.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/run-context.sh"
source "$LIB_DIR/tool-registry.sh"

# Validate tool choice
ralph_tool_validate "$TOOL" || exit 1

# Fail here rather than mid-iteration: the agent event stream is read by
# lib/stream-agent.mjs, so node has to be on PATH before any lock is taken.
if ! command -v node >/dev/null 2>&1 && ! command -v node.exe >/dev/null 2>&1; then
  echo "Error: Ralph needs Node.js (>= 18) on PATH to read the agent event stream."
  exit 1
fi

RUN_MODE=""
ACTIVE_TOOL_PID=""
ACTIVE_TOOL_PGID=""
ACTIVE_TOOL_WINPID=""
ACTIVE_STREAM_STATE_DIR=""
LAST_TOOL_DIAGNOSTIC_FILE=""
LAST_TOOL_EXIT_CODE=0
LAST_TOOL_SAW_COMPLETION="false"
CONSECUTIVE_TOOL_FAILURES=0
DEFER_TOOL_FAILURE_STOP="false"
RALPH_PROCESS_GROUP=""
ACTIVE_WORKTREE=""

source "$LIB_DIR/log.sh"
source "$LIB_DIR/process.sh"
source "$LIB_DIR/run-deps.sh"
source "$LIB_DIR/runs.sh"
source "$LIB_DIR/worktree.sh"
source "$LIB_DIR/notify.sh"
source "$LIB_DIR/sync.sh"
source "$LIB_DIR/tools.sh"
source "$LIB_DIR/story-state.sh"
source "$LIB_DIR/usage.sh"
source "$LIB_DIR/progress-bar.sh"
source "$LIB_DIR/run-status.sh"
source "$LIB_DIR/run-observers.sh"
source "$LIB_DIR/scaffold-cleanup.sh"
source "$LIB_DIR/merge-back.sh"
source "$LIB_DIR/consolidate.sh"
source "$LIB_DIR/run-bootstrap.sh"
source "$LIB_DIR/wrap-up-phases.sh"
source "$LIB_DIR/story-phase.sh"
source "$LIB_DIR/phase-controller.sh"

RALPH_PROCESS_GROUP="$(get_process_group "$$")"

if [[ "$USE_LEGACY" == "true" && -n "$RUN_ID" ]]; then
  echo "Error: Use either --run <run_id> or --legacy, not both."
  exit 1
fi

if [[ -z "$RUN_ID" && "$USE_LEGACY" != "true" ]]; then
  select_ralph_run
fi

if [[ -n "$RUN_ID" ]]; then
  validate_run_id "$RUN_ID"
  RUN_MODE="scoped"
else
  RUN_MODE="legacy"
fi

ralph_context_set_root_paths "$RUN_MODE" "$RUN_ID"

MERGE_LOCK_DIR=""
ACTIVE_CONTEXT_PROMPT_FILE=""
MERGE_PROMPT_FILE=""
CLEANUP_PROMPT_FILE=""
FINALIZE_PROMPT_FILE=""
ITERATION_PROMPT_FILE=""
CONSOLIDATE_PROMPT_FILE=""
UNBLOCK_PROMPT_FILE=""

if [[ "$RUN_MODE" == "scoped" ]]; then
  acquire_dir_lock "$RUN_LOCK_DIR" "Ralph run $RUN_ID"
fi

cleanup() {
  # First statement in the trap, so it reads the exit status that fired it
  # rather than whatever the lines below leave behind.
  local exit_code=$?

  # Release the pinned row first so shutdown messages scroll normally.
  ralph_observers_stop || true
  # Stamp the terminal state before anything else can fail: the orchestrator
  # reaps this child within a second of it exiting, and a status file frozen on
  # the last live phase would read as a run still working.
  if [[ "$exit_code" -eq 0 ]]; then
    ralph_observers_finish "succeeded" "$exit_code" || true
  else
    ralph_observers_finish "failed" "$exit_code" || true
  fi
  # The bill goes out on every exit path, including Ctrl-C: an interrupted run
  # still spent the tokens, and this is the last chance to say how many.
  ralph_usage_report || true
  ralph_usage_stop || true
  terminate_active_tool || true
  # The stream reader is not killed here: closing the tool also closes the FIFO
  # writer, so it reaches EOF on its own. Only its scratch dir needs clearing.
  if [[ -n "$ACTIVE_STREAM_STATE_DIR" ]]; then
    rm -rf "$ACTIVE_STREAM_STATE_DIR" || true
  fi
  if [[ "$RALPH_IS_WINDOWS" == "true" && -n "$ACTIVE_WORKTREE" && "$ACTIVE_WORKTREE" != "$REPO_ROOT" ]]; then
    windows_sweep_worktree_strays "$ACTIVE_WORKTREE" || true
  fi
  rm -f "$ACTIVE_CONTEXT_PROMPT_FILE" "$MERGE_PROMPT_FILE" "$CLEANUP_PROMPT_FILE" "$FINALIZE_PROMPT_FILE" "$ITERATION_PROMPT_FILE" "$CONSOLIDATE_PROMPT_FILE" "$UNBLOCK_PROMPT_FILE" || true
  release_dir_lock "$MERGE_LOCK_DIR" || true
  release_dir_lock "$RUN_LOCK_DIR" || true
}

cleanup_on_signal() {
  local signal_name="$1"
  local exit_code=130

  if [[ "$signal_name" == "TERM" ]]; then
    exit_code=143
  fi

  echo "" >&2
  ralph_log_line_err warn "Ralph received $signal_name; stopping active tool and cleaning up."
  exit "$exit_code"
}

trap cleanup EXIT
trap 'cleanup_on_signal INT' INT
trap 'cleanup_on_signal TERM' TERM
trap 'ralph_observers_resize || true' WINCH

ralph_bootstrap
ralph_phase_controller_init
ralph_phase_loop
