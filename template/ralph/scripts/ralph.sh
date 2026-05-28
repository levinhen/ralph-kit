#!/bin/bash
# Ralph Wiggum - Long-running AI agent loop
# Usage: ./ralph.sh [--run run_id|--legacy] [--tool claude|codex] [max_iterations]

set -e

# Parse arguments
TOOL="${RALPH_TOOL:-codex}"
MAX_ITERATIONS=10
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
      # Assume it's max_iterations if it's a number
      if [[ "$1" =~ ^[0-9]+$ ]]; then
        MAX_ITERATIONS="$1"
      fi
      shift
      ;;
  esac
done

# Validate tool choice
if [[ "$TOOL" != "claude" && "$TOOL" != "codex" ]]; then
  echo "Error: Invalid tool '$TOOL'. Must be 'claude' or 'codex'."
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
ROOT_CLAUDE_PROMPT_FILE="$SCRIPT_DIR/CLAUDE.md"
ROOT_CODEX_PROMPT_FILE="$SCRIPT_DIR/CODEX.md"
MERGE_BACK_PROMPT_FILE="$SCRIPT_DIR/MERGE_BACK.md"
MERGE_BACK_STATE_FILE="$RALPH_ROOT/.merge-back-done"
CONSOLIDATE_PROMPT_FILE_TEMPLATE="$SCRIPT_DIR/CONSOLIDATE.md"
CONSOLIDATION_STATE_FILE=""
CONSOLIDATION_STATE_REL_PATH=""
WORKTREE_ROOT="$REPO_ROOT/.worktrees"
RUNS_ROOT="$RALPH_ROOT/runs"
LOCK_ROOT="$RALPH_ROOT/locks"

RUN_MODE=""
ACTIVE_TOOL_PID=""
ACTIVE_TOOL_PGID=""
ACTIVE_TOOL_TEE_PID=""
RALPH_PROCESS_GROUP=""

LIB_DIR="$SCRIPT_DIR/lib"

source "$LIB_DIR/process.sh"
source "$LIB_DIR/runs.sh"
source "$LIB_DIR/worktree.sh"
source "$LIB_DIR/notify.sh"
source "$LIB_DIR/sync.sh"
source "$LIB_DIR/tools.sh"
source "$LIB_DIR/story-state.sh"
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
  terminate_active_tool || true
  rm -f "$ACTIVE_CONTEXT_PROMPT_FILE" "$MERGE_PROMPT_FILE" "$FINALIZE_PROMPT_FILE" "$ITERATION_PROMPT_FILE" "$CONSOLIDATE_PROMPT_FILE" || true
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
  echo "Ralph received $signal_name; stopping active tool and cleaning up." >&2
  exit "$exit_code"
}

trap cleanup EXIT
trap 'cleanup_on_signal INT' INT
trap 'cleanup_on_signal TERM' TERM

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
ACTIVE_SCRIPT_DIR="$ACTIVE_RALPH_ROOT/scripts"
CLAUDE_PROMPT_FILE="$ACTIVE_SCRIPT_DIR/CLAUDE.md"
CODEX_PROMPT_FILE="$ACTIVE_SCRIPT_DIR/CODEX.md"
ACTIVE_MERGE_BACK_PROMPT_FILE="$ACTIVE_SCRIPT_DIR/MERGE_BACK.md"

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

initialize_ralph_story_state

if [[ ! -f "$CLAUDE_PROMPT_FILE" ]]; then
  CLAUDE_PROMPT_FILE="$ROOT_CLAUDE_PROMPT_FILE"
fi

if [[ ! -f "$CODEX_PROMPT_FILE" ]]; then
  CODEX_PROMPT_FILE="$ROOT_CODEX_PROMPT_FILE"
fi

ACTIVE_PROMPT_FILE="$(resolve_tool_prompt active)"
if [[ ! -f "$ACTIVE_PROMPT_FILE" ]]; then
  echo "Error: Missing $TOOL prompt file: $ACTIVE_PROMPT_FILE"
  exit 1
fi

ROOT_PROMPT_FILE="$(resolve_tool_prompt root)"
if [[ ! -f "$ROOT_PROMPT_FILE" ]]; then
  echo "Error: Missing root $TOOL prompt file: $ROOT_PROMPT_FILE"
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

ACTIVE_CONTEXT_PROMPT_FILE=$(mktemp)
make_prompt_with_run_context "$ACTIVE_PROMPT_FILE" "$ACTIVE_CONTEXT_PROMPT_FILE"

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

echo "Starting Ralph - Tool: $TOOL - Max iterations: $MAX_ITERATIONS"
echo "Tool guard: timeout=${RALPH_TOOL_TIMEOUT_SECONDS:-0}s idle=${RALPH_TOOL_IDLE_TIMEOUT_SECONDS:-360}s"

for i in $(seq 1 $MAX_ITERATIONS); do
  sync_story_files_to_prd

  CURRENT_STORY_ID=$(jq -r '
    .userStories
    | map(select(.passes != true))
    | first
    | .id // empty
  ' "$PRD_FILE" 2>/dev/null || echo "")

  if [[ -n "$CURRENT_STORY_ID" ]]; then
    rm -f "$MERGE_BACK_STATE_FILE"
    [[ -n "$CONSOLIDATION_STATE_FILE" ]] && rm -f "$CONSOLIDATION_STATE_FILE"
  fi

  if [[ -z "$CURRENT_STORY_ID" ]]; then
    if merge_back_needed && ! merge_back_done; then
      echo ""
      echo "==============================================================="
      echo "  Ralph Merge-Back Round ($TOOL) - $TARGET_BRANCH -> $BASE_BRANCH"
      echo "==============================================================="

      if ! target_worktree_clean_for_merge; then
        if run_target_worktree_finalization; then
          echo "Ralph target worktree is clean. The next iteration will start merge-back."
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
        echo "Ralph merged $TARGET_BRANCH into $BASE_BRANCH. Consolidation round next."
        sleep 2
        continue
      fi

      MERGE_PROMPT_FILE=$(mktemp)
      make_prompt_with_run_context "$ROOT_PROMPT_FILE" "$MERGE_PROMPT_FILE"
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
        echo "Ralph merged $TARGET_BRANCH into $BASE_BRANCH. Consolidation round next."
        sleep 2
        continue
      fi

      if [[ "$TOOL" == "codex" && "$LAST_MESSAGE" == *"<promise>COMPLETE</promise>"* ]]; then
        echo "Warning: Codex reported COMPLETE, but merge-back marker was not written. Continuing."
      elif echo "$OUTPUT" | grep -q "<promise>COMPLETE</promise>"; then
        echo "Warning: Tool reported COMPLETE, but merge-back marker was not written. Continuing."
      fi

      echo "Merge-back round complete. Continuing..."
      sleep 2
      continue
    fi

    if consolidation_needed && ! consolidation_done; then
      echo ""
      echo "==============================================================="
      echo "  Ralph Consolidation Round ($TOOL) - $RUN_ID -> design-ledger"
      echo "==============================================================="

      CONSOLIDATE_PROMPT_FILE=$(mktemp)
      make_prompt_with_run_context "$ROOT_PROMPT_FILE" "$CONSOLIDATE_PROMPT_FILE"
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

After consolidation, \`ralph.sh\` will mechanically move \`ralph/runs/$RUN_ID/\` to \`ralph/archive/<date>-$RUN_ID/\` and create a separate archive commit. Do not do the archive move yourself.
EOF

      run_selected_tool "$REPO_ROOT" "$CONSOLIDATE_PROMPT_FILE"
      rm -f "$CONSOLIDATE_PROMPT_FILE"
      CONSOLIDATE_PROMPT_FILE=""

      if consolidation_done; then
        archive_consolidated_run
        echo ""
        if merge_back_needed; then
          echo "Ralph completed merge-back + consolidation for run $RUN_ID."
        else
          echo "Ralph completed consolidation for run $RUN_ID."
        fi
        notify_ralph_merged
        exit 0
      fi

      if [[ "$TOOL" == "codex" && "$LAST_MESSAGE" == *"<promise>COMPLETE</promise>"* ]]; then
        echo "Warning: Codex reported COMPLETE, but consolidation marker was not written. Continuing."
      elif echo "$OUTPUT" | grep -q "<promise>COMPLETE</promise>"; then
        echo "Warning: Tool reported COMPLETE, but consolidation marker was not written. Continuing."
      fi

      echo "Consolidation round complete (marker not yet written). Continuing..."
      sleep 2
      continue
    fi

    if [[ "$RUN_MODE" == "scoped" ]] && consolidation_done; then
      archive_consolidated_run
    fi

    echo ""
    echo "Ralph completed all tasks!"
    echo "All stories in $PRD_FILE already have passes=true"
    notify_ralph_stories_completed
    exit 0
  fi

  echo ""
  echo "==============================================================="
  echo "  Ralph Iteration $i of $MAX_ITERATIONS ($TOOL) - Target: $CURRENT_STORY_ID"
  echo "==============================================================="

  CURRENT_STORY_FILE="$(story_file_path "$CURRENT_STORY_ID")"
  if [[ ! -f "$CURRENT_STORY_FILE" ]]; then
    echo "Error: Missing current story file: $CURRENT_STORY_FILE"
    exit 1
  fi

  ITERATION_PROMPT_FILE=$(mktemp)
  make_prompt_with_story_context "$ACTIVE_CONTEXT_PROMPT_FILE" "$ITERATION_PROMPT_FILE" "$CURRENT_STORY_ID" "$CURRENT_STORY_FILE"

  PRE_ITERATION_HEAD=$(git -C "$ACTIVE_WORKTREE" rev-parse --verify HEAD 2>/dev/null || echo "")

  run_selected_tool "$ACTIVE_WORKTREE" "$ITERATION_PROMPT_FILE"
  rm -f "$ITERATION_PROMPT_FILE"
  ITERATION_PROMPT_FILE=""

  sync_story_files_to_prd_after_iteration "$PRE_ITERATION_HEAD"

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
    echo "Warning: $CURRENT_STORY_ID is still not marked passes=true in $PRD_FILE"
  fi

  if [[ "$ALL_COMPLETE" == "true" && merge_back_needed ]]; then
    echo "All stories are marked complete in $PRD_FILE. The next iteration will run the dedicated merge-back round."
  elif [[ "$ALL_COMPLETE" == "true" ]]; then
    echo ""
    echo "Ralph completed all tasks!"
    echo "Completed at iteration $i of $MAX_ITERATIONS"
    notify_ralph_stories_completed
    exit 0
  fi

  if [[ "$TOOL" == "codex" && "$LAST_MESSAGE" == *"<promise>COMPLETE</promise>"* ]]; then
    echo "Warning: Codex reported COMPLETE, but Ralph still has remaining work. Continuing."
  elif echo "$OUTPUT" | grep -q "<promise>COMPLETE</promise>"; then
    echo "Warning: Tool reported COMPLETE, but Ralph still has remaining work. Continuing."
  fi

  echo "Iteration $i complete. Continuing..."
  sleep 2
done

echo ""
echo "Ralph reached max iterations ($MAX_ITERATIONS) without completing all tasks."
echo "Check $PROGRESS_FILE for status."
notify_ralph_needs_attention
exit 1
