#!/bin/bash

# Prepare a Ralph run for the phase loop. The filesystem layout itself belongs
# to run-context.sh; this module performs the startup work that turns that
# layout into a validated, active run.

ralph_bootstrap_base_state() {
  local current_base_branch
  local current_base_sha
  local root_state_file_needs_write="false"

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
  current_base_branch=$(git -C "$REPO_ROOT" branch --show-current 2>/dev/null || echo "")
  current_base_sha=$(git -C "$REPO_ROOT" rev-parse --verify HEAD 2>/dev/null || echo "")
  BASE_BRANCH="$current_base_branch"
  BASE_SHA="$current_base_sha"

  if [[ "$RUN_MODE" != "scoped" ]]; then
    return 0
  fi

  if [[ -f "$ROOT_STATE_FILE" ]]; then
    BASE_BRANCH=$(jq -r '.baseBranch // empty' "$ROOT_STATE_FILE" 2>/dev/null || echo "")
    BASE_SHA=$(jq -r '.baseSha // empty' "$ROOT_STATE_FILE" 2>/dev/null || echo "")
  else
    mkdir -p "$RUN_DIR"
    root_state_file_needs_write="true"
  fi

  if [[ -z "$BASE_BRANCH" ]]; then
    if [[ -z "$current_base_branch" ]]; then
      echo "Error: Missing baseBranch in Ralph run state and could not determine the current local base branch: $ROOT_STATE_FILE"
      exit 1
    fi

    BASE_BRANCH="$current_base_branch"
    root_state_file_needs_write="true"
    echo "Backfilled Ralph run baseBranch from current branch: $BASE_BRANCH"
  fi

  if [[ -z "$BASE_SHA" ]]; then
    BASE_SHA="$current_base_sha"
    root_state_file_needs_write="true"
    echo "Backfilled Ralph run baseSha from current HEAD: $BASE_SHA"
  fi

  if [[ "$root_state_file_needs_write" == "true" ]]; then
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
}

ralph_bootstrap_worktree() {
  local target_worktree
  local existing_worktree

  ACTIVE_WORKTREE="$REPO_ROOT"

  if [[ -n "$TARGET_BRANCH" ]]; then
    target_worktree="$(ralph_context_worktree_path "$RUN_MODE" "$RUN_ID" "$TARGET_BRANCH")"
    existing_worktree="$(find_worktree_for_branch "$TARGET_BRANCH")"

    if [[ -n "$existing_worktree" ]]; then
      ACTIVE_WORKTREE="$existing_worktree"
    elif [[ "$BASE_BRANCH" != "$TARGET_BRANCH" ]]; then
      mkdir -p "$WORKTREE_ROOT"
      if git -C "$REPO_ROOT" show-ref --verify --quiet "refs/heads/$TARGET_BRANCH"; then
        git -C "$REPO_ROOT" worktree add "$target_worktree" "$TARGET_BRANCH"
      else
        if [[ -z "$BASE_BRANCH" ]]; then
          echo "Error: Could not determine the local base branch for creating $TARGET_BRANCH"
          exit 1
        fi
        git -C "$REPO_ROOT" worktree add -b "$TARGET_BRANCH" "$target_worktree" "$BASE_BRANCH"
      fi
      ACTIVE_WORKTREE="$target_worktree"
    fi
  fi

  ralph_context_set_active_paths "$ACTIVE_WORKTREE" "$RUN_MODE" "$RUN_ID"

  sync_root_ralph_inputs

  if [[ ! -f "$PRD_FILE" ]]; then
    echo "Error: Active Ralph PRD file not found in worktree: $PRD_FILE"
    exit 1
  fi
}

ralph_bootstrap_validate_backlog() {
  local unmet_run_deps=()
  local dep_run_id
  local prd_lint_output

  # A run's worktree is cut from the base branch, so a run it depends on has to
  # have landed there (or been archived) before this one can see that work. Runs
  # are resolved against the root checkout, never the worktree copy.
  if [[ "$RUN_MODE" == "scoped" ]]; then
    while IFS= read -r dep_run_id; do
      [[ -n "$dep_run_id" ]] || continue
      if run_dependency_satisfied "$RALPH_ROOT" "$REPO_ROOT" "$dep_run_id"; then
        continue
      fi
      if [[ -f "$RUNS_ROOT/$dep_run_id/prd.json" ]]; then
        unmet_run_deps+=("$dep_run_id")
      fi
    done < <(jq -r '
      (.dependsOnRuns // [])
      | if type == "array" then .[] else empty end
      | select(type == "string")
    ' "$ROOT_PRD_FILE" 2>/dev/null || true)

    if [[ "${#unmet_run_deps[@]}" -gt 0 ]]; then
      if [[ "${RALPH_IGNORE_RUN_DEPS:-0}" == "1" ]]; then
        echo "Warning: Ralph run $RUN_ID depends on runs that have not landed on $BASE_BRANCH yet:"
        printf '  - %s\n' "${unmet_run_deps[@]}"
        echo "Starting anyway because RALPH_IGNORE_RUN_DEPS=1."
      else
        echo "Error: Ralph run $RUN_ID depends on runs that have not landed on $BASE_BRANCH yet:"
        printf '  - %s\n' "${unmet_run_deps[@]}"
        echo "This run's worktree is created from $BASE_BRANCH, so it would not see their work."
        echo "Finish and merge those runs back first, or set RALPH_IGNORE_RUN_DEPS=1 to start anyway."
        exit 1
      fi
    fi
  fi

  # Catch malformed story and run dependency graphs before deriving state.
  if ! prd_lint_output="$(bash "$SCRIPT_DIR/lint-prd.sh" "$ROOT_PRD_FILE" 2>&1)"; then
    printf '%s\n' "$prd_lint_output"
    echo "Error: Ralph PRD failed validation: $ROOT_PRD_FILE"
    echo "Fix the problems above, then rerun."
    exit 1
  fi

  # Advisory lint findings are swallowed by the capture above; surface them.
  printf '%s\n' "$prd_lint_output" | grep '^WARN: ' || true

  initialize_ralph_story_state
}

ralph_bootstrap_prompt_files() {
  TOOL_PROMPT_FILE="$(resolve_tool_prompt)"
  if [[ ! -f "$TOOL_PROMPT_FILE" ]]; then
    echo "Error: Missing $TOOL prompt file: $TOOL_PROMPT_FILE"
    exit 1
  fi

  if [[ ! -f "$MERGE_BACK_PROMPT_FILE" ]]; then
    echo "Error: Missing merge-back prompt file: $MERGE_BACK_PROMPT_FILE"
    exit 1
  fi

  if scaffold_cleanup_needed && [[ ! -f "$CLEANUP_SCAFFOLD_PROMPT_FILE_TEMPLATE" ]]; then
    echo "Error: Missing scaffold cleanup prompt file: $CLEANUP_SCAFFOLD_PROMPT_FILE_TEMPLATE"
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
}

ralph_bootstrap_progress_history() {
  local current_branch
  local last_branch
  local archive_date
  local folder_name
  local archive_folder

  # Archive previous run if branch changed.
  if [[ -f "$PRD_FILE" && -f "$LAST_BRANCH_FILE" ]]; then
    current_branch=$(jq -r '.branchName // empty' "$PRD_FILE" 2>/dev/null || echo "")
    last_branch=$(cat "$LAST_BRANCH_FILE" 2>/dev/null || echo "")

    if [[ -n "$current_branch" && -n "$last_branch" && "$current_branch" != "$last_branch" ]]; then
      archive_date=$(date +%Y-%m-%d)
      folder_name=$(echo "$last_branch" | sed 's|^ralph/||')
      archive_folder="$ARCHIVE_DIR/$archive_date-$folder_name"

      echo "Archiving previous run: $last_branch"
      mkdir -p "$archive_folder"
      [[ -f "$PRD_FILE" ]] && cp "$PRD_FILE" "$archive_folder/"
      [[ -f "$PROGRESS_FILE" ]] && cp "$PROGRESS_FILE" "$archive_folder/"
      [[ -d "$PROGRESS_DIR" ]] && cp -R "$PROGRESS_DIR" "$archive_folder/"
      [[ -d "$STORIES_DIR" ]] && cp -R "$STORIES_DIR" "$archive_folder/"
      echo "   Archived to: $archive_folder"

      echo "# Ralph Progress Log" > "$PROGRESS_FILE"
      echo "Started: $(date)" >> "$PROGRESS_FILE"
      echo "---" >> "$PROGRESS_FILE"
    fi
  fi

  # Track current branch.
  if [[ -f "$PRD_FILE" ]]; then
    current_branch=$(jq -r '.branchName // empty' "$PRD_FILE" 2>/dev/null || echo "")
    if [[ -n "$current_branch" ]]; then
      echo "$current_branch" > "$LAST_BRANCH_FILE"
    fi
  fi

  # Initialize progress file if it does not exist.
  if [[ ! -f "$PROGRESS_FILE" ]]; then
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
}

ralph_bootstrap_reporting() {
  local progress_label="$RUN_ID"

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
  if scaffold_cleanup_needed; then
    echo "Scaffold cleanup state file: $SCAFFOLD_CLEANUP_STATE_FILE"
  fi
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

  if [[ -z "$progress_label" && -n "$TARGET_BRANCH" ]]; then
    progress_label="${TARGET_BRANCH##*/}"
  fi
  # The status file tracks the worktree's PRD, not the root's.
  ralph_observers_start "$STATUS_ROOT" "$PRD_FILE" "$RUN_ID_LABEL" "$TOOL" "$progress_label"
}

ralph_bootstrap() {
  ralph_bootstrap_base_state
  ralph_bootstrap_worktree
  ralph_bootstrap_validate_backlog
  ralph_bootstrap_prompt_files
  ralph_bootstrap_progress_history
  ralph_bootstrap_reporting
}
