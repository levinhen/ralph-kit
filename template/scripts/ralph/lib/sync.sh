#!/bin/bash

sync_root_ralph_inputs() {
  copy_file_if_missing "$ROOT_PRD_FILE" "$PRD_FILE"
  copy_file_if_missing "$ROOT_PROGRESS_FILE" "$PROGRESS_FILE"
  copy_dir_if_missing "$ROOT_PROGRESS_DIR" "$PROGRESS_DIR"
  copy_dir_if_missing "$(dirname "$ROOT_PRD_FILE")/stories" "$STORIES_DIR"
  copy_state_if_missing_base "$ROOT_STATE_FILE" "$STATE_FILE"
  copy_file_if_exists "$ROOT_CLAUDE_PROMPT_FILE" "$CLAUDE_PROMPT_FILE"
  copy_file_if_exists "$ROOT_CODEX_PROMPT_FILE" "$CODEX_PROMPT_FILE"
  copy_file_if_exists "$MERGE_BACK_PROMPT_FILE" "$ACTIVE_MERGE_BACK_PROMPT_FILE"
}

root_overlay_status() {
  git -C "$REPO_ROOT" status --porcelain --untracked-files=all -- \
    . \
    ':(exclude).worktrees' \
    ':(exclude)scripts/ralph/locks' \
    ':(exclude)scripts/ralph/runs' \
    ':(exclude)scripts/ralph/.last-branch' \
    ':(exclude)scripts/ralph/prd.json' \
    ':(exclude)scripts/ralph/progress.txt' \
    ':(exclude)scripts/ralph/progress' \
    ':(exclude)scripts/ralph/stories' \
    ':(exclude)scripts/ralph/CLAUDE.md' \
    ':(exclude)scripts/ralph/CODEX.md' \
    ':(exclude)scripts/ralph/MERGE_BACK.md' \
    ':(exclude)scripts/ralph/CONSOLIDATE.md' \
    ':(exclude)scripts/ralph/.consolidation-done-*' \
    ':(exclude)scripts/ralph/ralph.sh' \
    ':(exclude)scripts/ralph/lib'
}

active_overlay_status() {
  git -C "$ACTIVE_WORKTREE" status --porcelain --untracked-files=all -- \
    . \
    ':(exclude).worktrees' \
    ':(exclude)scripts/ralph/locks' \
    ':(exclude)scripts/ralph/runs' \
    ':(exclude)scripts/ralph/.last-branch' \
    ':(exclude)scripts/ralph/prd.json' \
    ':(exclude)scripts/ralph/progress.txt' \
    ':(exclude)scripts/ralph/progress' \
    ':(exclude)scripts/ralph/stories' \
    ':(exclude)scripts/ralph/CLAUDE.md' \
    ':(exclude)scripts/ralph/CODEX.md' \
    ':(exclude)scripts/ralph/MERGE_BACK.md' \
    ':(exclude)scripts/ralph/CONSOLIDATE.md' \
    ':(exclude)scripts/ralph/.consolidation-done-*' \
    ':(exclude)scripts/ralph/ralph.sh' \
    ':(exclude)scripts/ralph/lib'
}

apply_root_overlay_to_worktree() {
  local temp_patch
  local root_status

  if [[ "$ACTIVE_WORKTREE" == "$REPO_ROOT" ]]; then
    return
  fi

  root_status="$(root_overlay_status)"
  if [[ -z "$root_status" ]]; then
    return
  fi

  if [[ -n "$(active_overlay_status)" ]]; then
    echo "Error: Active Ralph worktree has uncommitted changes. Clean it before syncing root changes into $ACTIVE_WORKTREE"
    exit 1
  fi

  temp_patch=$(mktemp)
  git -C "$REPO_ROOT" diff --binary HEAD -- \
    . \
    ':(exclude).worktrees' \
    ':(exclude)scripts/ralph/locks' \
    ':(exclude)scripts/ralph/runs' \
    ':(exclude)scripts/ralph/.last-branch' \
    ':(exclude)scripts/ralph/prd.json' \
    ':(exclude)scripts/ralph/progress.txt' \
    ':(exclude)scripts/ralph/progress' \
    ':(exclude)scripts/ralph/stories' \
    ':(exclude)scripts/ralph/CLAUDE.md' \
    ':(exclude)scripts/ralph/CODEX.md' \
    ':(exclude)scripts/ralph/MERGE_BACK.md' \
    ':(exclude)scripts/ralph/CONSOLIDATE.md' \
    ':(exclude)scripts/ralph/.consolidation-done-*' \
    ':(exclude)scripts/ralph/ralph.sh' \
    ':(exclude)scripts/ralph/lib' > "$temp_patch"

  if [[ -s "$temp_patch" ]]; then
    if ! git -C "$ACTIVE_WORKTREE" apply --3way --whitespace=nowarn "$temp_patch"; then
      rm -f "$temp_patch"
      echo "Error: Failed to apply root tracked changes into $ACTIVE_WORKTREE"
      echo "Resolve the conflict manually or clean the target Ralph worktree before retrying."
      exit 1
    fi
  fi
  rm -f "$temp_patch"

  while IFS= read -r -d '' relpath; do
    local source="$REPO_ROOT/$relpath"
    local dest="$ACTIVE_WORKTREE/$relpath"
    mkdir -p "$(dirname "$dest")"
    cp "$source" "$dest"
  done < <(
    git -C "$REPO_ROOT" ls-files --others --exclude-standard -z -- \
      . \
      ':(exclude).worktrees' \
      ':(exclude)scripts/ralph/locks' \
      ':(exclude)scripts/ralph/runs' \
      ':(exclude)scripts/ralph/.last-branch' \
      ':(exclude)scripts/ralph/prd.json' \
      ':(exclude)scripts/ralph/progress.txt' \
      ':(exclude)scripts/ralph/progress' \
      ':(exclude)scripts/ralph/stories' \
      ':(exclude)scripts/ralph/CLAUDE.md' \
      ':(exclude)scripts/ralph/CODEX.md' \
      ':(exclude)scripts/ralph/MERGE_BACK.md' \
      ':(exclude)scripts/ralph/ralph.sh' \
      ':(exclude)scripts/ralph/lib'
  )

  echo "Synced root uncommitted changes into Ralph worktree: $ACTIVE_WORKTREE"
  echo "Note: merge-back later works best when the base worktree is clean."
}
