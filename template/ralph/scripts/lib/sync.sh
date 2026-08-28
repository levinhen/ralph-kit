#!/bin/bash

# Pathspecs of files that ralph generates or that the base/active worktrees
# manage independently. Used by overlay sync to ignore agent-produced state.
_RALPH_OVERLAY_EXCLUDES=(
  ':(exclude).worktrees'
  ':(exclude)ralph/locks'
  ':(exclude)ralph/runs'
  ':(exclude)ralph/archive'
  ':(exclude)ralph/.last-branch'
  ':(exclude)ralph/.merge-back-done'
  ':(exclude)ralph/.consolidation-done-*'
  ':(exclude)ralph/prd.json'
  ':(exclude)ralph/progress.txt'
  ':(exclude)ralph/progress'
  ':(exclude)ralph/stories'
  ':(exclude)ralph/state.json'
  ':(exclude)ralph/scripts'
)

sync_root_ralph_inputs() {
  copy_file_if_missing "$ROOT_PRD_FILE" "$PRD_FILE"
  copy_file_if_missing "$ROOT_PROGRESS_FILE" "$PROGRESS_FILE"
  copy_dir_if_missing "$ROOT_PROGRESS_DIR" "$PROGRESS_DIR"
  copy_dir_if_missing "$(dirname "$ROOT_PRD_FILE")/stories" "$STORIES_DIR"
  copy_state_if_missing_base "$ROOT_STATE_FILE" "$STATE_FILE"
}

root_overlay_status() {
  git -C "$REPO_ROOT" status --porcelain --untracked-files=all -- . "${_RALPH_OVERLAY_EXCLUDES[@]}"
}

active_overlay_status() {
  git -C "$ACTIVE_WORKTREE" status --porcelain --untracked-files=all -- . "${_RALPH_OVERLAY_EXCLUDES[@]}"
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
  git -C "$REPO_ROOT" diff --binary HEAD -- . "${_RALPH_OVERLAY_EXCLUDES[@]}" > "$temp_patch"

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
    git -C "$REPO_ROOT" ls-files --others --exclude-standard -z -- . "${_RALPH_OVERLAY_EXCLUDES[@]}"
  )

  echo "Synced root uncommitted changes into Ralph worktree: $ACTIVE_WORKTREE"
  echo "Note: merge-back later works best when the base worktree is clean."
}
