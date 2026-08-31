#!/bin/bash

# Canonical Ralph filesystem layout and identifier rules.
#
# This module locates itself from BASH_SOURCE, so it can be sourced first from a
# top-level script or from another library without relying on variables or
# source order supplied by its caller. Re-sourcing it is intentionally a no-op:
# a caller may already have switched the context from the default legacy layout
# to a scoped run.

if [[ "${RALPH_RUN_CONTEXT_LOADED:-}" == "1" ]] \
  && type ralph_context_init_roots >/dev/null 2>&1; then
  return 0 2>/dev/null || exit 0
fi
RALPH_RUN_CONTEXT_LOADED=1

_RALPH_CONTEXT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_RALPH_CONTEXT_SCRIPT_DIR="$(cd "$_RALPH_CONTEXT_LIB_DIR/.." && pwd)"

ralph_run_id_is_valid() {
  local run_id="${1:-}"
  [[ "$run_id" =~ ^[A-Za-z0-9._-]+$ && "$run_id" != "." && "$run_id" != ".." ]]
}

ralph_story_id_is_valid() {
  local story_id="${1:-}"
  [[ "$story_id" =~ ^[A-Za-z0-9._-]+$ && "$story_id" != "." && "$story_id" != ".." ]]
}

ralph_print_invalid_run_id() {
  local run_id="$1"

  echo "Error: Invalid run id '$run_id'. Use only letters, numbers, dot, underscore, and dash; '.' and '..' are not allowed." >&2
}

# Compatibility front door used by ralph.sh and create-run.sh. Small helper
# CLIs historically print a shorter error and therefore use the predicate
# above while sharing the same validation rule.
validate_run_id() {
  local run_id="$1"

  if ! ralph_run_id_is_valid "$run_id"; then
    ralph_print_invalid_run_id "$run_id"
    exit 1
  fi
}

# Story paths use story IDs as filenames. Keep the established error text for
# callers in story-state.sh while centralising the accepted character set.
validate_story_id_for_file() {
  local story_id="$1"

  if ! ralph_story_id_is_valid "$story_id"; then
    echo "Error: Story id '$story_id' cannot be used as a Ralph story filename." >&2
    exit 1
  fi
}

sanitize_branch_name() {
  echo "$1" | sed 's|^refs/heads/||; s|[/:\\]|-|g'
}

ralph_context_validate_mode() {
  local mode="${1:-}"

  if [[ "$mode" != "legacy" && "$mode" != "scoped" ]]; then
    echo "Error: Invalid Ralph run mode '$mode'. Must be 'legacy' or 'scoped'." >&2
    return 1
  fi
}

# Roots that do not change when a run moves into its linked worktree. Prompt
# files deliberately remain anchored to the checkout that launched ralph.sh;
# the loop reads and embeds them before invoking the agent.
ralph_context_init_roots() {
  local script_dir="${1:-$_RALPH_CONTEXT_SCRIPT_DIR}"

  if [[ ! -d "$script_dir" ]]; then
    echo "Error: Ralph scripts directory not found: $script_dir" >&2
    return 1
  fi

  SCRIPT_DIR="$(cd "$script_dir" && pwd)"
  LIB_DIR="$SCRIPT_DIR/lib"
  PROMPT_ROOT="$SCRIPT_DIR"
  RALPH_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
  REPO_ROOT="$(cd "$RALPH_ROOT/.." && pwd)"
  RUNS_ROOT="$RALPH_ROOT/runs"
  STATUS_ROOT="$RALPH_ROOT/status"
  WORKTREE_ROOT="$REPO_ROOT/.worktrees"
  LOCK_ROOT="$RALPH_ROOT/locks"

  CLAUDE_PROMPT_FILE="$PROMPT_ROOT/CLAUDE.md"
  CODEX_PROMPT_FILE="$PROMPT_ROOT/CODEX.md"
  PI_PROMPT_FILE="$PROMPT_ROOT/PI.md"
  MERGE_BACK_PROMPT_FILE="$PROMPT_ROOT/MERGE_BACK.md"
  CLEANUP_SCAFFOLD_PROMPT_FILE_TEMPLATE="$PROMPT_ROOT/CLEANUP_SCAFFOLD.md"
  CONSOLIDATE_PROMPT_FILE_TEMPLATE="$PROMPT_ROOT/CONSOLIDATE.md"
  UNBLOCK_STORY_PROMPT_FILE_TEMPLATE="$PROMPT_ROOT/UNBLOCK_STORY.md"
}

# Paths owned by the checkout that launches the loop. For a scoped run these
# remain on the base checkout while story state advances in a linked worktree;
# merge markers, locks, status, and final archival all use this root context.
ralph_context_set_root_paths() {
  local mode="$1"
  local run_id="${2:-}"

  ralph_context_validate_mode "$mode" || return 1
  if [[ "$mode" == "scoped" ]] && ! ralph_run_id_is_valid "$run_id"; then
    ralph_print_invalid_run_id "$run_id"
    return 1
  fi

  RUN_MODE="$mode"
  RUN_ID_LABEL="legacy"
  RUN_DIR=""
  ROOT_RUN_DIR="$RALPH_ROOT"
  ROOT_PRD_FILE="$RALPH_ROOT/prd.json"
  ROOT_PROGRESS_FILE="$RALPH_ROOT/progress.txt"
  ROOT_PROGRESS_DIR="$RALPH_ROOT/progress"
  ROOT_SHARED_MEMORY_FILE="$ROOT_PROGRESS_DIR/shared-memory.json"
  ROOT_STORIES_DIR="$RALPH_ROOT/stories"
  ROOT_ARCHIVE_DIR="$RALPH_ROOT/archive"
  ROOT_LAST_BRANCH_FILE="$RALPH_ROOT/.last-branch"
  ROOT_STATE_FILE="$RALPH_ROOT/state.json"
  MERGE_BACK_STATE_FILE="$RALPH_ROOT/.merge-back-done"
  SCAFFOLD_CLEANUP_STATE_FILE="$RALPH_ROOT/.scaffold-cleanup-done"
  CONSOLIDATION_STATE_FILE=""
  CONSOLIDATION_STATE_REL_PATH=""
  RUN_LOCK_DIR=""

  if [[ "$mode" == "scoped" ]]; then
    RUN_ID_LABEL="$run_id"
    RUN_DIR="$RUNS_ROOT/$run_id"
    ROOT_RUN_DIR="$RUN_DIR"
    ROOT_PRD_FILE="$RUN_DIR/prd.json"
    ROOT_PROGRESS_FILE="$RUN_DIR/progress.txt"
    ROOT_PROGRESS_DIR="$RUN_DIR/progress"
    ROOT_SHARED_MEMORY_FILE="$ROOT_PROGRESS_DIR/shared-memory.json"
    ROOT_STORIES_DIR="$RUN_DIR/stories"
    ROOT_ARCHIVE_DIR="$RUN_DIR/archive"
    ROOT_LAST_BRANCH_FILE="$RUN_DIR/.last-branch"
    ROOT_STATE_FILE="$RUN_DIR/state.json"
    MERGE_BACK_STATE_FILE="$RUN_DIR/.merge-back-done"
    SCAFFOLD_CLEANUP_STATE_FILE="$RUN_DIR/.scaffold-cleanup-done"
    CONSOLIDATION_STATE_FILE="$RALPH_ROOT/.consolidation-done-$run_id"
    CONSOLIDATION_STATE_REL_PATH="ralph/.consolidation-done-$run_id"
    RUN_LOCK_DIR="$LOCK_ROOT/run-$run_id.lock"
  fi
}

# Paths visible to an agent invocation. ACTIVE_WORKTREE may be the base checkout
# (legacy/no target branch) or a linked worktree. Relative prompt paths are
# produced alongside their absolute counterparts so prompt builders never
# reconstruct the layout independently.
ralph_context_set_active_paths() {
  local active_worktree="$1"
  local mode="$2"
  local run_id="${3:-}"

  ralph_context_validate_mode "$mode" || return 1
  if [[ -z "$active_worktree" ]]; then
    echo "Error: Missing active Ralph worktree path." >&2
    return 1
  fi
  if [[ "$mode" == "scoped" ]] && ! ralph_run_id_is_valid "$run_id"; then
    ralph_print_invalid_run_id "$run_id"
    return 1
  fi

  ACTIVE_WORKTREE="$active_worktree"
  ACTIVE_RALPH_ROOT="$ACTIVE_WORKTREE/ralph"
  ACTIVE_RUN_DIR=""

  if [[ "$mode" == "scoped" ]]; then
    ACTIVE_RUN_DIR="$ACTIVE_RALPH_ROOT/runs/$run_id"
    PRD_FILE="$ACTIVE_RUN_DIR/prd.json"
    PROGRESS_FILE="$ACTIVE_RUN_DIR/progress.txt"
    PROGRESS_DIR="$ACTIVE_RUN_DIR/progress"
    SHARED_MEMORY_FILE="$PROGRESS_DIR/shared-memory.json"
    STORIES_DIR="$ACTIVE_RUN_DIR/stories"
    ARCHIVE_DIR="$ACTIVE_RALPH_ROOT/archive"
    LAST_BRANCH_FILE="$ACTIVE_RUN_DIR/.last-branch"
    STATE_FILE="$ACTIVE_RUN_DIR/state.json"
    PRD_REL_PATH="ralph/runs/$run_id/prd.json"
    PROGRESS_REL_PATH="ralph/runs/$run_id/progress.txt"
    PROGRESS_REL_DIR="ralph/runs/$run_id/progress"
    SHARED_MEMORY_REL_PATH="ralph/runs/$run_id/progress/shared-memory.json"
    STORIES_REL_DIR="ralph/runs/$run_id/stories"
    STATE_REL_PATH="ralph/runs/$run_id/state.json"
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
}

ralph_context_worktree_path() {
  local mode="$1"
  local run_id="${2:-}"
  local branch="${3:-}"

  ralph_context_validate_mode "$mode" || return 1
  if [[ "$mode" == "scoped" ]]; then
    if ! ralph_run_id_is_valid "$run_id"; then
      ralph_print_invalid_run_id "$run_id"
      return 1
    fi
    echo "$WORKTREE_ROOT/$run_id"
  else
    echo "$WORKTREE_ROOT/$(sanitize_branch_name "$branch")"
  fi
}

# A directly sourced context starts in the legacy/base-checkout layout. Callers
# switch it to a scoped run only after CLI selection has resolved the run ID.
ralph_context_init_roots "$_RALPH_CONTEXT_SCRIPT_DIR"
ralph_context_set_root_paths "legacy" ""
