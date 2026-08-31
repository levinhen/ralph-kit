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

# Validate tool choice
if [[ "$TOOL" != "claude" && "$TOOL" != "codex" && "$TOOL" != "pi" ]]; then
  echo "Error: Invalid tool '$TOOL'. Must be 'claude', 'codex', or 'pi'."
  exit 1
fi

# Fail here rather than mid-iteration: the agent event stream is read by
# lib/stream-agent.mjs, so node has to be on PATH before any lock is taken.
if ! command -v node >/dev/null 2>&1 && ! command -v node.exe >/dev/null 2>&1; then
  echo "Error: Ralph needs Node.js (>= 18) on PATH to read the agent event stream."
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Layout: <repo>/ralph/scripts/  ←  SCRIPT_DIR
#         <repo>/ralph/          ←  RALPH_ROOT (runs/, archive/, locks/, legacy state)
#         <repo>/                ←  REPO_ROOT
RALPH_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$RALPH_ROOT/.." && pwd)"
# Legacy-mode root-level files live in $RALPH_ROOT, not $SCRIPT_DIR — only static
# code/prompts belong under scripts/.
ROOT_PRD_FILE="$RALPH_ROOT/prd.json"
ROOT_PROGRESS_FILE="$RALPH_ROOT/progress.txt"
ROOT_PROGRESS_DIR="$RALPH_ROOT/progress"
ROOT_SHARED_MEMORY_FILE="$ROOT_PROGRESS_DIR/shared-memory.json"
ROOT_ARCHIVE_DIR="$RALPH_ROOT/archive"
ROOT_LAST_BRANCH_FILE="$RALPH_ROOT/.last-branch"
# Agent playbooks are always read from this checkout's scripts directory. Ralph
# itself reads them and folds them into a temporary prompt file; the agent never
# opens them, so there is no reason to keep a second copy inside the worktree.
CLAUDE_PROMPT_FILE="$SCRIPT_DIR/CLAUDE.md"
CODEX_PROMPT_FILE="$SCRIPT_DIR/CODEX.md"
PI_PROMPT_FILE="$SCRIPT_DIR/PI.md"
MERGE_BACK_PROMPT_FILE="$SCRIPT_DIR/MERGE_BACK.md"
MERGE_BACK_STATE_FILE="$RALPH_ROOT/.merge-back-done"
CONSOLIDATE_PROMPT_FILE_TEMPLATE="$SCRIPT_DIR/CONSOLIDATE.md"
UNBLOCK_STORY_PROMPT_FILE_TEMPLATE="$SCRIPT_DIR/UNBLOCK_STORY.md"
CONSOLIDATION_STATE_FILE=""
CONSOLIDATION_STATE_REL_PATH=""
WORKTREE_ROOT="$REPO_ROOT/.worktrees"
RUNS_ROOT="$RALPH_ROOT/runs"
LOCK_ROOT="$RALPH_ROOT/locks"
# Live run status, one file per run, read by orchestrate.sh while the run is
# redirected to a log file. Kept out of ralph/runs/ on purpose: consolidation
# archives that directory and stages it, and this is throwaway runtime state.
STATUS_ROOT="$RALPH_ROOT/status"

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

LIB_DIR="$SCRIPT_DIR/lib"

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
# After progress-bar.sh: run-status.sh wraps it, so the wrapped functions have
# to exist first.
source "$LIB_DIR/run-status.sh"
source "$LIB_DIR/merge-back.sh"
source "$LIB_DIR/consolidate.sh"

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

ROOT_STATE_FILE="$RALPH_ROOT/state.json"
RUN_ID_LABEL="legacy"
RUN_LOCK_DIR=""
MERGE_LOCK_DIR=""
ACTIVE_CONTEXT_PROMPT_FILE=""
MERGE_PROMPT_FILE=""
FINALIZE_PROMPT_FILE=""
ITERATION_PROMPT_FILE=""
CONSOLIDATE_PROMPT_FILE=""
UNBLOCK_PROMPT_FILE=""
ROOT_STATE_FILE_WAS_MISSING="false"

if [[ "$RUN_MODE" == "scoped" ]]; then
  RUN_DIR="$RUNS_ROOT/$RUN_ID"
  ROOT_PRD_FILE="$RUN_DIR/prd.json"
  ROOT_PROGRESS_FILE="$RUN_DIR/progress.txt"
  ROOT_PROGRESS_DIR="$RUN_DIR/progress"
  ROOT_SHARED_MEMORY_FILE="$ROOT_PROGRESS_DIR/shared-memory.json"
  ROOT_ARCHIVE_DIR="$RUN_DIR/archive"
  ROOT_LAST_BRANCH_FILE="$RUN_DIR/.last-branch"
  ROOT_STATE_FILE="$RUN_DIR/state.json"
  MERGE_BACK_STATE_FILE="$RUN_DIR/.merge-back-done"
  CONSOLIDATION_STATE_FILE="$RALPH_ROOT/.consolidation-done-$RUN_ID"
  CONSOLIDATION_STATE_REL_PATH="ralph/.consolidation-done-$RUN_ID"
  RUN_ID_LABEL="$RUN_ID"
  RUN_LOCK_DIR="$LOCK_ROOT/run-$RUN_ID.lock"
  acquire_dir_lock "$RUN_LOCK_DIR" "Ralph run $RUN_ID"
fi

cleanup() {
  # First statement in the trap, so it reads the exit status that fired it
  # rather than whatever the lines below leave behind.
  local exit_code=$?

  # Release the pinned row first so shutdown messages scroll normally.
  ralph_progress_stop || true
  # Stamp the terminal state before anything else can fail: the orchestrator
  # reaps this child within a second of it exiting, and a status file frozen on
  # the last live phase would read as a run still working.
  if [[ "$exit_code" -eq 0 ]]; then
    ralph_status_finish "succeeded" "$exit_code" || true
  else
    ralph_status_finish "failed" "$exit_code" || true
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
  rm -f "$ACTIVE_CONTEXT_PROMPT_FILE" "$MERGE_PROMPT_FILE" "$FINALIZE_PROMPT_FILE" "$ITERATION_PROMPT_FILE" "$CONSOLIDATE_PROMPT_FILE" "$UNBLOCK_PROMPT_FILE" || true
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
trap 'ralph_progress_resize || true' WINCH

if [[ ! -f "$ROOT_PRD_FILE" ]]; then
  if [[ "$RUN_MODE" == "scoped" ]]; then
    echo "Error: Missing Ralph run PRD file: $ROOT_PRD_FILE"
    echo "Create it at ralph/runs/$RUN_ID/prd.json, then rerun with --run $RUN_ID."
  else
    echo "Error: Missing Ralph PRD file: $ROOT_PRD_FILE"
  fi
  exit 1
fi

git -C "$REPO_ROOT" worktree prune >/dev/null 2>&1 || true

require_git_base

TARGET_BRANCH=$(jq -r '.branchName // empty' "$ROOT_PRD_FILE" 2>/dev/null || echo "")
CURRENT_BASE_BRANCH=$(git -C "$REPO_ROOT" branch --show-current 2>/dev/null || echo "")
CURRENT_BASE_SHA=$(git -C "$REPO_ROOT" rev-parse --verify HEAD 2>/dev/null || echo "")
BASE_BRANCH="$CURRENT_BASE_BRANCH"
BASE_SHA="$CURRENT_BASE_SHA"

if [[ "$RUN_MODE" == "scoped" ]]; then
  ROOT_STATE_FILE_NEEDS_WRITE="false"

  if [[ -f "$ROOT_STATE_FILE" ]]; then
    BASE_BRANCH=$(jq -r '.baseBranch // empty' "$ROOT_STATE_FILE" 2>/dev/null || echo "")
    BASE_SHA=$(jq -r '.baseSha // empty' "$ROOT_STATE_FILE" 2>/dev/null || echo "")
  else
    mkdir -p "$RUN_DIR"
    ROOT_STATE_FILE_WAS_MISSING="true"
    ROOT_STATE_FILE_NEEDS_WRITE="true"
  fi

  if [[ -z "$BASE_BRANCH" ]]; then
    if [[ -z "$CURRENT_BASE_BRANCH" ]]; then
      echo "Error: Missing baseBranch in Ralph run state and could not determine the current local base branch: $ROOT_STATE_FILE"
      exit 1
    fi

    BASE_BRANCH="$CURRENT_BASE_BRANCH"
    ROOT_STATE_FILE_NEEDS_WRITE="true"
    echo "Backfilled Ralph run baseBranch from current branch: $BASE_BRANCH"
  fi

  if [[ -z "$BASE_SHA" ]]; then
    BASE_SHA="$CURRENT_BASE_SHA"
    ROOT_STATE_FILE_NEEDS_WRITE="true"
    echo "Backfilled Ralph run baseSha from current HEAD: $BASE_SHA"
  fi

  if [[ "$ROOT_STATE_FILE_NEEDS_WRITE" == "true" ]]; then
    mkdir -p "$(dirname "$ROOT_STATE_FILE")"
    jq -n \
      --arg runId "$RUN_ID" \
      --arg baseBranch "$BASE_BRANCH" \
      --arg baseSha "$BASE_SHA" \
      --arg targetBranch "$TARGET_BRANCH" \
      --arg status "ready" \
      '{
        runId: $runId,
        baseBranch: $baseBranch,
        baseSha: $baseSha,
        targetBranch: $targetBranch,
        status: $status
      }' > "$ROOT_STATE_FILE"
  fi
fi

ACTIVE_WORKTREE="$REPO_ROOT"

if [ -n "$TARGET_BRANCH" ]; then
  if [[ "$RUN_MODE" == "scoped" ]]; then
    TARGET_WORKTREE="$WORKTREE_ROOT/$RUN_ID"
  else
    TARGET_WORKTREE="$WORKTREE_ROOT/$(sanitize_branch_name "$TARGET_BRANCH")"
  fi

  EXISTING_WORKTREE="$(find_worktree_for_branch "$TARGET_BRANCH")"

  if [ -n "$EXISTING_WORKTREE" ]; then
    ACTIVE_WORKTREE="$EXISTING_WORKTREE"
  elif [ "$BASE_BRANCH" != "$TARGET_BRANCH" ]; then
    mkdir -p "$WORKTREE_ROOT"
    if git -C "$REPO_ROOT" show-ref --verify --quiet "refs/heads/$TARGET_BRANCH"; then
      git -C "$REPO_ROOT" worktree add "$TARGET_WORKTREE" "$TARGET_BRANCH"
    else
      if [ -z "$BASE_BRANCH" ]; then
        echo "Error: Could not determine the local base branch for creating $TARGET_BRANCH"
        exit 1
      fi
      git -C "$REPO_ROOT" worktree add -b "$TARGET_BRANCH" "$TARGET_WORKTREE" "$BASE_BRANCH"
    fi
    ACTIVE_WORKTREE="$TARGET_WORKTREE"
  fi
fi

ACTIVE_RALPH_ROOT="$ACTIVE_WORKTREE/ralph"

if [[ "$RUN_MODE" == "scoped" ]]; then
  ACTIVE_RUN_DIR="$ACTIVE_RALPH_ROOT/runs/$RUN_ID"
  PRD_FILE="$ACTIVE_RUN_DIR/prd.json"
  PROGRESS_FILE="$ACTIVE_RUN_DIR/progress.txt"
  PROGRESS_DIR="$ACTIVE_RUN_DIR/progress"
  SHARED_MEMORY_FILE="$PROGRESS_DIR/shared-memory.json"
  STORIES_DIR="$ACTIVE_RUN_DIR/stories"
  ARCHIVE_DIR="$ACTIVE_RALPH_ROOT/archive"
  LAST_BRANCH_FILE="$ACTIVE_RUN_DIR/.last-branch"
  STATE_FILE="$ACTIVE_RUN_DIR/state.json"
  PRD_REL_PATH="ralph/runs/$RUN_ID/prd.json"
  PROGRESS_REL_PATH="ralph/runs/$RUN_ID/progress.txt"
  PROGRESS_REL_DIR="ralph/runs/$RUN_ID/progress"
  SHARED_MEMORY_REL_PATH="ralph/runs/$RUN_ID/progress/shared-memory.json"
  STORIES_REL_DIR="ralph/runs/$RUN_ID/stories"
  STATE_REL_PATH="ralph/runs/$RUN_ID/state.json"
else
  PRD_FILE="$ACTIVE_RALPH_ROOT/prd.json"
  PROGRESS_FILE="$ACTIVE_RALPH_ROOT/progress.txt"
  PROGRESS_DIR="$ACTIVE_RALPH_ROOT/progress"
  SHARED_MEMORY_FILE="$PROGRESS_DIR/shared-memory.json"
  STORIES_DIR="$ACTIVE_RALPH_ROOT/stories"
  ARCHIVE_DIR="$ACTIVE_RALPH_ROOT/archive"
  LAST_BRANCH_FILE="$ACTIVE_RALPH_ROOT/.last-branch"
  STATE_FILE="$ACTIVE_RALPH_ROOT/state.json"
  PRD_REL_PATH="ralph/prd.json"
  PROGRESS_REL_PATH="ralph/progress.txt"
  PROGRESS_REL_DIR="ralph/progress"
  SHARED_MEMORY_REL_PATH="ralph/progress/shared-memory.json"
  STORIES_REL_DIR="ralph/stories"
  STATE_REL_PATH="ralph/state.json"
fi

sync_root_ralph_inputs

if [[ ! -f "$PRD_FILE" ]]; then
  echo "Error: Active Ralph PRD file not found in worktree: $PRD_FILE"
  exit 1
fi

# A run's worktree is cut from the base branch, so a run it depends on has to
# have landed there (or been archived) before this one can see that work. Runs
# are resolved against the root checkout, never the worktree copy: the worktree
# is a base-branch snapshot from when it was created, so a dependency that
# merged back later is invisible there. A dependency that does not exist at all
# on the root side is left for the lint below, which names it precisely.
if [[ "$RUN_MODE" == "scoped" ]]; then
  UNMET_RUN_DEPS=()

  while IFS= read -r DEP_RUN_ID; do
    [[ -n "$DEP_RUN_ID" ]] || continue
    if run_dependency_satisfied "$RALPH_ROOT" "$REPO_ROOT" "$DEP_RUN_ID"; then
      continue
    fi
    if [[ -f "$RALPH_ROOT/runs/$DEP_RUN_ID/prd.json" ]]; then
      UNMET_RUN_DEPS+=("$DEP_RUN_ID")
    fi
  done < <(jq -r '
    (.dependsOnRuns // [])
    | if type == "array" then .[] else empty end
    | select(type == "string")
  ' "$ROOT_PRD_FILE" 2>/dev/null || true)

  if [[ "${#UNMET_RUN_DEPS[@]}" -gt 0 ]]; then
    if [[ "${RALPH_IGNORE_RUN_DEPS:-0}" == "1" ]]; then
      echo "Warning: Ralph run $RUN_ID depends on runs that have not landed on $BASE_BRANCH yet:"
      printf '  - %s\n' "${UNMET_RUN_DEPS[@]}"
      echo "Starting anyway because RALPH_IGNORE_RUN_DEPS=1."
    else
      echo "Error: Ralph run $RUN_ID depends on runs that have not landed on $BASE_BRANCH yet:"
      printf '  - %s\n' "${UNMET_RUN_DEPS[@]}"
      echo "This run's worktree is created from $BASE_BRANCH, so it would not see their work."
      echo "Finish and merge those runs back first, or set RALPH_IGNORE_RUN_DEPS=1 to start anyway."
      exit 1
    fi
  fi
fi

# Catch a malformed backlog before any story state is derived from it: broken
# ids, dangling or forward `dependsOn` edges, cycles, and bad `dependsOnRuns`
# references all make the run's story order meaningless. A missing or stale
# dependency audit is only a `WARN:` line and does not stop the run. Lint the
# root-side PRD, not the worktree copy: they were just synced, and only the root
# side can resolve `dependsOnRuns` references against the live runs/ and
# archive/ dirs.
if ! PRD_LINT_OUTPUT="$(bash "$SCRIPT_DIR/lint-prd.sh" "$ROOT_PRD_FILE" 2>&1)"; then
  printf '%s\n' "$PRD_LINT_OUTPUT"
  echo "Error: Ralph PRD failed validation: $ROOT_PRD_FILE"
  echo "Fix the problems above, then rerun."
  exit 1
fi

# Advisory lint findings are swallowed by the capture above; surface them.
printf '%s\n' "$PRD_LINT_OUTPUT" | grep '^WARN: ' || true

initialize_ralph_story_state

TOOL_PROMPT_FILE="$(resolve_tool_prompt)"
if [[ ! -f "$TOOL_PROMPT_FILE" ]]; then
  echo "Error: Missing $TOOL prompt file: $TOOL_PROMPT_FILE"
  exit 1
fi

if [[ ! -f "$MERGE_BACK_PROMPT_FILE" ]]; then
  echo "Error: Missing merge-back prompt file: $MERGE_BACK_PROMPT_FILE"
  exit 1
fi

if [[ "$RUN_MODE" == "scoped" && ! -f "$CONSOLIDATE_PROMPT_FILE_TEMPLATE" ]]; then
  echo "Error: Missing consolidation prompt file: $CONSOLIDATE_PROMPT_FILE_TEMPLATE"
  exit 1
fi

if [[ ! -f "$UNBLOCK_STORY_PROMPT_FILE_TEMPLATE" ]]; then
  echo "Error: Missing story unblock prompt file: $UNBLOCK_STORY_PROMPT_FILE_TEMPLATE"
  exit 1
fi

ACTIVE_CONTEXT_PROMPT_FILE=$(mktemp)
make_prompt_with_run_context "$TOOL_PROMPT_FILE" "$ACTIVE_CONTEXT_PROMPT_FILE"

# Archive previous run if branch changed
if [ -f "$PRD_FILE" ] && [ -f "$LAST_BRANCH_FILE" ]; then
  CURRENT_BRANCH=$(jq -r '.branchName // empty' "$PRD_FILE" 2>/dev/null || echo "")
  LAST_BRANCH=$(cat "$LAST_BRANCH_FILE" 2>/dev/null || echo "")

  if [ -n "$CURRENT_BRANCH" ] && [ -n "$LAST_BRANCH" ] && [ "$CURRENT_BRANCH" != "$LAST_BRANCH" ]; then
    DATE=$(date +%Y-%m-%d)
    FOLDER_NAME=$(echo "$LAST_BRANCH" | sed 's|^ralph/||')
    ARCHIVE_FOLDER="$ARCHIVE_DIR/$DATE-$FOLDER_NAME"

    echo "Archiving previous run: $LAST_BRANCH"
    mkdir -p "$ARCHIVE_FOLDER"
    [ -f "$PRD_FILE" ] && cp "$PRD_FILE" "$ARCHIVE_FOLDER/"
    [ -f "$PROGRESS_FILE" ] && cp "$PROGRESS_FILE" "$ARCHIVE_FOLDER/"
    [ -d "$PROGRESS_DIR" ] && cp -R "$PROGRESS_DIR" "$ARCHIVE_FOLDER/"
    [ -d "$STORIES_DIR" ] && cp -R "$STORIES_DIR" "$ARCHIVE_FOLDER/"
    echo "   Archived to: $ARCHIVE_FOLDER"

    echo "# Ralph Progress Log" > "$PROGRESS_FILE"
    echo "Started: $(date)" >> "$PROGRESS_FILE"
    echo "---" >> "$PROGRESS_FILE"
  fi
fi

# Track current branch
if [ -f "$PRD_FILE" ]; then
  CURRENT_BRANCH=$(jq -r '.branchName // empty' "$PRD_FILE" 2>/dev/null || echo "")
  if [ -n "$CURRENT_BRANCH" ]; then
    echo "$CURRENT_BRANCH" > "$LAST_BRANCH_FILE"
  fi
fi

# Initialize progress file if it doesn't exist
if [ ! -f "$PROGRESS_FILE" ]; then
  echo "# Ralph Progress Log" > "$PROGRESS_FILE"
  echo "Started: $(date)" >> "$PROGRESS_FILE"
  echo "---" >> "$PROGRESS_FILE"
fi

if [[ "$RUN_MODE" == "legacy" && ! -f "$ROOT_PROGRESS_FILE" ]]; then
  echo "# Ralph Progress Log" > "$ROOT_PROGRESS_FILE"
  echo "Started: $(date)" >> "$ROOT_PROGRESS_FILE"
  echo "---" >> "$ROOT_PROGRESS_FILE"
fi

if [[ "$RUN_MODE" == "legacy" ]]; then
  apply_root_overlay_to_worktree
fi

echo "Ralph run mode: $RUN_MODE"
if [[ "$RUN_MODE" == "scoped" ]]; then
  echo "Ralph run ID: $RUN_ID"
  echo "Using Ralph state: $STATE_FILE"
fi
echo "Using Ralph worktree: $ACTIVE_WORKTREE"
echo "Using Ralph PRD: $PRD_FILE"
echo "Using Ralph progress log: $PROGRESS_FILE"
echo "Using Ralph progress dir: $PROGRESS_DIR"
echo "Using Ralph story files: $STORIES_DIR"
if merge_back_needed; then
  echo "Merge-back target base branch: $BASE_BRANCH"
  echo "Merge-back state file: $MERGE_BACK_STATE_FILE"
fi
if [[ -n "$CONSOLIDATION_STATE_FILE" ]]; then
  echo "Consolidation state file: $CONSOLIDATION_STATE_FILE"
fi

echo "Starting Ralph - Tool: $TOOL"
echo "Tool guard: timeout=${RALPH_TOOL_TIMEOUT_SECONDS:-0}s idle=${RALPH_TOOL_IDLE_TIMEOUT_SECONDS:-360}s"
# The ledger has to exist before the status ticker forks: the ticker inherits
# the path and then polls the file for the run's running total.
ralph_usage_start

# What to call this run in the status row. Parallel runs (see orchestrate.sh) put
# otherwise identical rows in several windows, and the run id is what tells them
# apart; a legacy run has none, so its branch is the next best handle.
PROGRESS_LABEL="$RUN_ID"
if [[ -z "$PROGRESS_LABEL" && -n "$TARGET_BRANCH" ]]; then
  PROGRESS_LABEL="${TARGET_BRANCH##*/}"
fi
ralph_progress_start "$PRD_FILE" "$PROGRESS_LABEL"
# The status file tracks the worktree's PRD, not the root's: story passes land
# in the worktree copy every round, while the root copy only catches up at
# merge-back. A watcher wants the live number, not the merged one.
ralph_status_start "$STATUS_ROOT" "$PRD_FILE" "$RUN_ID_LABEL" "$TOOL"

# Story rounds are self-limiting: a story that does not reach passes=true gets
# one unblock round below, which either finishes it, restructures the backlog
# around it, or ends the run. The wrap-up rounds are the ones that can spin,
# because each one re-runs its agent until a marker file appears - so they carry
# their own budgets instead of sharing one iteration cap with the stories.
MAX_FINALIZE_ROUNDS="${RALPH_MAX_FINALIZE_ROUNDS:-3}"
MAX_MERGE_BACK_ROUNDS="${RALPH_MAX_MERGE_BACK_ROUNDS:-3}"
MAX_CONSOLIDATION_ROUNDS="${RALPH_MAX_CONSOLIDATION_ROUNDS:-3}"
FINALIZE_ROUNDS=0
MERGE_BACK_ROUNDS=0
CONSOLIDATION_ROUNDS=0

# An unblock round that restructures the backlog hands control back to the loop
# instead of ending the run, which is the one way a story failure does not walk
# forward. Bound it: a split that keeps needing repair is a PRD problem a human
# has to look at, not one more restructure away from working.
MAX_RESTRUCTURES="${RALPH_MAX_RESTRUCTURES:-2}"
RESTRUCTURES=0

# Counts every round the loop runs, wrap-up rounds included. Nothing is bounded
# by it; it exists so the terminal, the progress row, and the unblock prompt
# can all refer to the same round number.
ROUND=0

wrap_up_budget_exhausted() {
  local phase="$1"
  local limit="$2"

  ralph_progress_stop || true
  echo ""
  ralph_log_line error "Ralph ran the $phase round $limit times without it completing."
  ralph_log_line error "Check $PROGRESS_FILE and the output above before rerunning."
  notify_ralph_needs_attention "$phase did not complete after $limit rounds"
  exit 1
}

while true; do
  ROUND=$((ROUND + 1))
  # An unblock round can add stories to the PRD. Back-fill their story files
  # before syncing back, so a new story is a normal story by the time the loop
  # picks it up. Existing files are left alone.
  initialize_story_files
  sync_story_files_to_prd

  CURRENT_STORY_ID=$(jq -r '
    .userStories
    | map(select(.passes != true))
    | first
    | .id // empty
  ' "$PRD_FILE" 2>/dev/null || echo "")

  if [[ -n "$CURRENT_STORY_ID" ]]; then
    ralph_status_update "working" "$CURRENT_STORY_ID" "$ROUND"
    rm -f "$MERGE_BACK_STATE_FILE"
    [[ -n "$CONSOLIDATION_STATE_FILE" ]] && rm -f "$CONSOLIDATION_STATE_FILE"
    # Back in the story phase, so the wrap-up markers above were just cleared
    # and any earlier wrap-up attempt no longer describes the current state.
    FINALIZE_ROUNDS=0
    MERGE_BACK_ROUNDS=0
    CONSOLIDATION_ROUNDS=0
  fi

  if [[ -z "$CURRENT_STORY_ID" ]]; then
    if merge_back_needed && ! merge_back_done; then
      ralph_status_update "merge-back" "" "$ROUND"
      echo ""
      ralph_log_banner merge "Ralph Merge-Back Round ($TOOL) - $TARGET_BRANCH -> $BASE_BRANCH"

      if ! target_worktree_clean_for_merge; then
        FINALIZE_ROUNDS=$((FINALIZE_ROUNDS + 1))
        if [[ "$FINALIZE_ROUNDS" -gt "$MAX_FINALIZE_ROUNDS" ]]; then
          wrap_up_budget_exhausted "worktree finalization" "$MAX_FINALIZE_ROUNDS"
        fi
        ralph_status_update "finalizing" "" "$ROUND"
        if run_target_worktree_finalization; then
          ralph_log_line success "Ralph target worktree is clean. The next round will start merge-back."
        fi
        sleep 2
        continue
      fi

      if [[ -z "$MERGE_LOCK_DIR" ]]; then
        MERGE_LOCK_DIR="$LOCK_ROOT/merge-$(sanitize_branch_name "$BASE_BRANCH").lock"
        acquire_dir_lock "$MERGE_LOCK_DIR" "merge-back for $BASE_BRANCH"
      fi

      if run_git_merge_back; then
        echo ""
        ralph_log_line success "Ralph merged $TARGET_BRANCH into $BASE_BRANCH. Consolidation round next."
        sleep 2
        continue
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
        continue
      fi

      if [[ "$TOOL" == "codex" && "$LAST_MESSAGE" == *"<promise>COMPLETE</promise>"* ]]; then
        ralph_log_line warn "Warning: Codex reported COMPLETE, but merge-back marker was not written. Continuing."
      elif echo "$OUTPUT" | grep -q "<promise>COMPLETE</promise>"; then
        ralph_log_line warn "Warning: Tool reported COMPLETE, but merge-back marker was not written. Continuing."
      fi

      echo "Merge-back round complete. Continuing..."
      sleep 2
      continue
    fi

    if consolidation_needed && ! consolidation_done; then
      CONSOLIDATION_ROUNDS=$((CONSOLIDATION_ROUNDS + 1))
      if [[ "$CONSOLIDATION_ROUNDS" -gt "$MAX_CONSOLIDATION_ROUNDS" ]]; then
        wrap_up_budget_exhausted "consolidation" "$MAX_CONSOLIDATION_ROUNDS"
      fi

      ralph_status_update "consolidating" "" "$ROUND"
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
        ralph_status_update "complete" "" "$ROUND"
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
      continue
    fi

    if [[ "$RUN_MODE" == "scoped" ]] && consolidation_done; then
      archive_consolidated_run
    fi

    ralph_status_update "complete" "" "$ROUND"
    echo ""
    ralph_log_line success "Ralph completed all tasks!"
    ralph_log_line success "All stories in $PRD_FILE already have passes=true"
    notify_ralph_stories_completed
    exit 0
  fi

  echo ""
  ralph_log_banner story "Ralph Round $ROUND ($TOOL) - Target: $CURRENT_STORY_ID"

  CURRENT_STORY_FILE="$(story_file_path "$CURRENT_STORY_ID")"
  if [[ ! -f "$CURRENT_STORY_FILE" ]]; then
    ralph_log_line error "Error: Missing current story file: $CURRENT_STORY_FILE"
    exit 1
  fi

  ITERATION_PROMPT_FILE=$(mktemp)
  make_prompt_with_story_context "$ACTIVE_CONTEXT_PROMPT_FILE" "$ITERATION_PROMPT_FILE" "$CURRENT_STORY_ID" "$CURRENT_STORY_FILE"

  PRE_ITERATION_HEAD=$(git -C "$ACTIVE_WORKTREE" rev-parse --verify HEAD 2>/dev/null || echo "")

  # A story round is never retried blindly. Even when the underlying CLI fails,
  # let the loop reach the file-based story check so it can run the unblock
  # round with useful evidence in hand.
  DEFER_TOOL_FAILURE_STOP="true"
  run_selected_tool "$ACTIVE_WORKTREE" "$ITERATION_PROMPT_FILE"
  DEFER_TOOL_FAILURE_STOP="false"
  rm -f "$ITERATION_PROMPT_FILE"
  ITERATION_PROMPT_FILE=""

  FAILED_ROUND_LAST_MESSAGE="$LAST_MESSAGE"
  if [[ -z "$FAILED_ROUND_LAST_MESSAGE" ]]; then
    FAILED_ROUND_LAST_MESSAGE="$OUTPUT"
  fi
  FAILED_ROUND_TOOL_EXIT_CODE="$LAST_TOOL_EXIT_CODE"
  FAILED_ROUND_SAW_COMPLETION="$LAST_TOOL_SAW_COMPLETION"
  FAILED_ROUND_DIAGNOSTIC_FILE="$LAST_TOOL_DIAGNOSTIC_FILE"

  sync_story_files_to_prd_after_iteration "$PRE_ITERATION_HEAD"
  FAILED_ROUND_AFTER_HEAD=$(git -C "$ACTIVE_WORKTREE" rev-parse --verify HEAD 2>/dev/null || echo "")
  ralph_status_update "checking" "$CURRENT_STORY_ID" "$ROUND"

  STORY_PASSED=$(jq -r --arg story_id "$CURRENT_STORY_ID" '
    .userStories[]
    | select(.id == $story_id)
    | .passes
  ' "$PRD_FILE" 2>/dev/null || echo "false")

  ALL_COMPLETE=$(jq -r '
    if (.userStories | length) == 0 then
      false
    else
      (.userStories | all(.passes == true))
    end
  ' "$PRD_FILE" 2>/dev/null || echo "false")

  if [[ "$STORY_PASSED" != "true" ]]; then
    ralph_log_line warn "Warning: $CURRENT_STORY_ID is still not marked passes=true in $PRD_FILE"

    # The unblock round may rewrite the backlog rather than the code, so capture
    # what the split looks like now. passes/notes are excluded: those move on
    # every ordinary round and say nothing about the structure.
    PRE_UNBLOCK_STRUCTURE=$(prd_structure_fingerprint)

    ralph_status_update "unblocking" "$CURRENT_STORY_ID" "$ROUND"
    echo ""
    ralph_log_banner unblock "Ralph Story Unblock Round ($TOOL) - Target: $CURRENT_STORY_ID"
    ralph_log_line unblock "The failed story is not retried blindly. One round decides whether it is genuinely blocked, then finishes it or restructures the backlog around it."

    UNBLOCK_PROMPT_FILE=$(mktemp)
    make_story_unblock_prompt \
      "$UNBLOCK_PROMPT_FILE" \
      "$CURRENT_STORY_ID" \
      "$CURRENT_STORY_FILE" \
      "$ROUND" \
      "$FAILED_ROUND_TOOL_EXIT_CODE" \
      "$FAILED_ROUND_SAW_COMPLETION" \
      "$PRE_ITERATION_HEAD" \
      "$FAILED_ROUND_AFTER_HEAD" \
      "$FAILED_ROUND_DIAGNOSTIC_FILE" \
      "$FAILED_ROUND_LAST_MESSAGE"

    # The failed round already moved on from PRE_ITERATION_HEAD, so the unblock
    # round needs its own baseline for the PRD sync amend.
    UNBLOCK_HEAD_BEFORE=$(git -C "$ACTIVE_WORKTREE" rev-parse --verify HEAD 2>/dev/null || echo "")

    DEFER_TOOL_FAILURE_STOP="true"
    run_selected_tool "$ACTIVE_WORKTREE" "$UNBLOCK_PROMPT_FILE"
    DEFER_TOOL_FAILURE_STOP="false"
    rm -f "$UNBLOCK_PROMPT_FILE"
    UNBLOCK_PROMPT_FILE=""

    UNBLOCK_MESSAGE="$LAST_MESSAGE"
    if [[ -z "$UNBLOCK_MESSAGE" ]]; then
      UNBLOCK_MESSAGE="$OUTPUT"
    fi
    UNBLOCK_DIAGNOSTIC_FILE="$LAST_TOOL_DIAGNOSTIC_FILE"

    sync_story_files_to_prd_after_iteration "$UNBLOCK_HEAD_BEFORE"
    ralph_status_update "checking" "$CURRENT_STORY_ID" "$ROUND"

    STORY_PASSED=$(jq -r --arg story_id "$CURRENT_STORY_ID" '
      .userStories[]
      | select(.id == $story_id)
      | .passes
    ' "$PRD_FILE" 2>/dev/null || echo "false")

    if [[ "$STORY_PASSED" == "true" ]]; then
      ralph_status_unblock_outcome "finished" || true
      echo ""
      ralph_log_line success "Ralph finished $CURRENT_STORY_ID in the unblock round: it was unfinished, not blocked."
      # Hand back to the top of the loop rather than deciding anything here: the
      # next iteration re-derives the backlog and takes the all-complete,
      # merge-back and consolidation paths on its own.
      echo "Round $ROUND complete. Continuing..."
      sleep 2
      continue
    fi

    # A story can also leave the round still failing because the round agreed it
    # was blocked and reshaped the backlog instead. That is a legitimate outcome:
    # the next round starts on whatever the new split puts first.
    if [[ "$(prd_structure_fingerprint)" != "$PRE_UNBLOCK_STRUCTURE" ]]; then
      RESTRUCTURES=$((RESTRUCTURES + 1))
      ralph_status_unblock_outcome "restructured" || true
      echo ""
      ralph_log_line unblock "The unblock round judged $CURRENT_STORY_ID blocked and restructured the backlog in $PRD_REL_PATH."
      ralph_log_line unblock "Stories now: $(jq -r '[.userStories[].id] | join(", ")' "$PRD_FILE" 2>/dev/null || echo "unreadable")"
      if [[ "$RESTRUCTURES" -le "$MAX_RESTRUCTURES" ]]; then
        ralph_log_line unblock "Restructure $RESTRUCTURES of $MAX_RESTRUCTURES for this run. Continuing on the new split..."
        sleep 2
        continue
      fi

      ralph_progress_stop || true
      echo ""
      ralph_log_line unblock "================= Ralph Story Unblock Round ================="
      printf '%s\n' "$UNBLOCK_MESSAGE"
      ralph_log_line unblock "============================================================="
      ralph_log_line error "Ralph restructured the backlog $RESTRUCTURES times in this run (limit $MAX_RESTRUCTURES) and stories are still failing."
      ralph_log_line error "A split that keeps needing repair is a PRD problem. Review $PRD_REL_PATH and the reports above before rerunning."
      notify_ralph_needs_attention "backlog restructured $RESTRUCTURES times without the run progressing"
      exit 1
    fi

    ralph_status_unblock_outcome "stopped" || true
    # Release the pinned row before printing the durable handoff so the report
    # remains readable at the user's shell prompt.
    ralph_progress_stop || true
    echo ""
    ralph_log_line unblock "================= Ralph Story Unblock Round ================="
    if [[ -n "$UNBLOCK_MESSAGE" ]]; then
      printf '%s\n' "$UNBLOCK_MESSAGE"
    else
      echo "The unblock agent produced no final report (exit $LAST_TOOL_EXIT_CODE)."
    fi
    # Only a failed CLI leaves a diagnostic file behind, so each of these lines
    # appears exactly when that round's tool itself went wrong.
    if [[ -n "$UNBLOCK_DIAGNOSTIC_FILE" ]]; then
      echo "The unblock round's raw events are available at: $UNBLOCK_DIAGNOSTIC_FILE"
    fi
    if [[ -n "$FAILED_ROUND_DIAGNOSTIC_FILE" ]]; then
      echo "The failed implementation round's raw events are available at: $FAILED_ROUND_DIAGNOSTIC_FILE"
    fi
    ralph_log_line unblock "============================================================="
    ralph_log_line error "Ralph stopped: the unblock round neither finished $CURRENT_STORY_ID nor restructured the backlog around it. Review the report above before rerunning."
    notify_ralph_needs_attention "story $CURRENT_STORY_ID still failing after the unblock round"
    exit 1
  fi

  if [[ "$ALL_COMPLETE" == "true" ]] && merge_back_needed; then
    ralph_log_line success "All stories are marked complete in $PRD_FILE. The next round will run the dedicated merge-back round."
  elif [[ "$ALL_COMPLETE" == "true" ]]; then
    ralph_status_update "complete" "" "$ROUND"
    echo ""
    ralph_log_line success "Ralph completed all tasks!"
    ralph_log_line success "Completed at round $ROUND"
    notify_ralph_stories_completed
    exit 0
  fi

  if [[ "$TOOL" == "codex" && "$LAST_MESSAGE" == *"<promise>COMPLETE</promise>"* ]]; then
    ralph_log_line warn "Warning: Codex reported COMPLETE, but Ralph still has remaining work. Continuing."
  elif echo "$OUTPUT" | grep -q "<promise>COMPLETE</promise>"; then
    ralph_log_line warn "Warning: Tool reported COMPLETE, but Ralph still has remaining work. Continuing."
  fi

  echo "Round $ROUND complete. Continuing..."
  sleep 2
done

