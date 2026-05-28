#!/bin/bash

merge_back_needed() {
  [[ -n "$TARGET_BRANCH" && -n "$BASE_BRANCH" && "$TARGET_BRANCH" != "$BASE_BRANCH" ]]
}

merge_back_done() {
  if [[ ! -f "$MERGE_BACK_STATE_FILE" ]]; then
    return 1
  fi

  grep -qx "status=done" "$MERGE_BACK_STATE_FILE" \
    && grep -qx "base_branch=$BASE_BRANCH" "$MERGE_BACK_STATE_FILE" \
    && grep -qx "target_branch=$TARGET_BRANCH" "$MERGE_BACK_STATE_FILE"
}

target_worktree_status() {
  git -C "$ACTIVE_WORKTREE" status --porcelain --untracked-files=all -- \
    . \
    ':(exclude).worktrees' \
    ':(exclude)scripts/ralph/locks' \
    ':(exclude)scripts/ralph/.merge-back-done' \
    ':(exclude)scripts/ralph/runs/*/.merge-back-done' \
    ':(exclude)scripts/ralph/.consolidation-done-*'
}

target_worktree_clean_for_merge() {
  [[ -z "$(target_worktree_status)" ]]
}

run_target_worktree_finalization() {
  local dirty

  dirty="$(target_worktree_status)"
  if [[ -z "$dirty" ]]; then
    return 0
  fi

  echo "Ralph target worktree has uncommitted content; asking $TOOL to commit it before merge-back."
  git -C "$ACTIVE_WORKTREE" status --short

  FINALIZE_PROMPT_FILE=$(mktemp)
  make_prompt_with_run_context "$ACTIVE_PROMPT_FILE" "$FINALIZE_PROMPT_FILE"
  cat <<EOF >> "$FINALIZE_PROMPT_FILE"

## Final Worktree Consolidation Round

All user stories are already marked complete, but the Ralph target worktree still has uncommitted or untracked content. Do not pick another user story and do not start merge-back from the base branch in this round.

Your goal is to make sure the final contents of the Ralph worktree are present on \`$TARGET_BRANCH\` before merge-back begins.

Required behavior:

1. Stay in the Ralph worktree supplied in the run context: \`$ACTIVE_WORKTREE\`.
2. Inspect \`git status\` and the dirty files deliberately.
3. Preserve intended run output. Do not discard, reset, or leave worktree content uncommitted unless it is clearly unrelated temporary output, and record that decision in the progress log.
4. Run focused checks for the changed files when practical.
5. Stage and commit all intended Ralph run changes, including PRD and progress updates, onto \`$TARGET_BRANCH\`.
6. Re-read \`git status --short\`; the worktree must be clean except ignored files before you finish.
7. Do not emit \`<promise>COMPLETE</promise>\` unless the commit succeeded and the worktree is clean.
EOF

  run_selected_tool "$ACTIVE_WORKTREE" "$FINALIZE_PROMPT_FILE"
  rm -f "$FINALIZE_PROMPT_FILE"
  FINALIZE_PROMPT_FILE=""

  dirty="$(target_worktree_status)"
  if [[ -n "$dirty" ]]; then
    echo "Ralph target worktree is still dirty after finalization; merge-back is deferred."
    git -C "$ACTIVE_WORKTREE" status --short
    return 1
  fi

  return 0
}

write_merge_back_marker() {
  cat > "$MERGE_BACK_STATE_FILE" <<EOF
status=done
base_branch=$BASE_BRANCH
target_branch=$TARGET_BRANCH
EOF
}

base_merge_status() {
  git -C "$REPO_ROOT" status --porcelain --untracked-files=all -- \
    . \
    ':(exclude).worktrees' \
    ':(exclude)scripts/ralph/locks' \
    ':(exclude)scripts/ralph/.merge-back-done' \
    ':(exclude)scripts/ralph/runs/*/.merge-back-done' \
    ':(exclude)scripts/ralph/.consolidation-done-*' \
    ':(exclude)scripts/ralph/ralph.sh' \
    ':(exclude)scripts/ralph/lib' \
    ':(exclude)scripts/ralph/MERGE_BACK.md' \
    ':(exclude)scripts/ralph/CONSOLIDATE.md'
}

print_base_dirty_for_merge() {
  local dirty

  dirty="$(base_merge_status)"
  if [[ -z "$dirty" ]]; then
    return 1
  fi

  echo "Base worktree has local changes; keeping them visible while starting Git merge-back."
  git -C "$REPO_ROOT" status --short
  return 0
}

append_git_merge_back_progress() {
  cat >> "$ROOT_PROGRESS_FILE" <<EOF
## $(date '+%Y-%m-%d %H:%M') - MERGE-BACK
- What was implemented: Merged completed Ralph branch \`$TARGET_BRANCH\` into \`$BASE_BRANCH\` using Git merge.
- Files changed: See the merge commit for the complete file list.
- Quality checks run and result: Not run by \`ralph.sh\` during automatic merge-back; story-level checks are recorded above.
- Learnings for future iterations:
  - Patterns discovered: Ralph merge-back should create a real two-parent Git merge commit so the completed story commits remain visible in history.
  - Gotchas encountered: If the base worktree is dirty, \`ralph.sh\` keeps local changes visible and delegates merge completion instead of silently stashing work aside.
  - Useful context: The merge completion marker is written only after the merge commit succeeds.
---
EOF
}

append_git_merge_back_progress_json() {
  local merge_back_jsonl

  [[ -n "$ROOT_PROGRESS_DIR" ]] || return
  mkdir -p "$ROOT_PROGRESS_DIR"
  if [[ ! -f "$ROOT_SHARED_MEMORY_FILE" ]]; then
    echo '[]' > "$ROOT_SHARED_MEMORY_FILE"
  fi

  merge_back_jsonl="$ROOT_PROGRESS_DIR/MERGE-BACK.jsonl"
  jq -n -c \
    --arg timestamp "$(date '+%Y-%m-%d %H:%M')" \
    --arg targetBranch "$TARGET_BRANCH" \
    --arg baseBranch "$BASE_BRANCH" \
    '{
      timestamp: $timestamp,
      storyId: "MERGE-BACK",
      summary: ("Merged completed Ralph branch `" + $targetBranch + "` into `" + $baseBranch + "` using Git merge."),
      filesChanged: ["See the merge commit for the complete file list."],
      checks: ["Not run by ralph.sh during automatic merge-back; story-level checks are recorded separately."],
      learnings: {
        patterns: ["Ralph merge-back should create a real two-parent Git merge commit so completed story commits remain visible in history."],
        gotchas: ["If the base worktree is dirty, ralph.sh keeps local changes visible and delegates merge completion instead of silently stashing work aside."],
        context: ["The merge completion marker is written only after the merge commit succeeds."]
      }
    }' >> "$merge_back_jsonl"
}

run_git_merge_back() {
  local current_branch
  local had_base_dirty="false"

  current_branch=$(git -C "$REPO_ROOT" branch --show-current 2>/dev/null || echo "")
  if [[ "$current_branch" != "$BASE_BRANCH" ]]; then
    echo "Error: Merge-back for run $RUN_ID_LABEL must run from base branch $BASE_BRANCH, but base worktree is on $current_branch."
    echo "Switch the base worktree to $BASE_BRANCH and rerun this Ralph loop."
    exit 1
  fi

  if git -C "$REPO_ROOT" merge-base --is-ancestor "$TARGET_BRANCH" HEAD; then
    echo "Ralph branch $TARGET_BRANCH is already merged into $BASE_BRANCH."
    write_merge_back_marker
    return 0
  fi

  if print_base_dirty_for_merge; then
    had_base_dirty="true"
  fi

  echo "Starting Git merge-back: $TARGET_BRANCH -> $BASE_BRANCH"
  if git -C "$REPO_ROOT" merge --no-ff --no-commit "$TARGET_BRANCH"; then
    if [[ "$had_base_dirty" == "true" ]]; then
      echo "Git merge-back started with pre-existing base worktree changes still visible."
      echo "Delegating completion to $TOOL so local changes are not silently left aside."
      return 1
    fi

    append_git_merge_back_progress
    append_git_merge_back_progress_json
    git -C "$REPO_ROOT" add "$ROOT_PROGRESS_FILE"
    git -C "$REPO_ROOT" add "$ROOT_PROGRESS_DIR"
    git -C "$REPO_ROOT" commit -m "Merge branch '$TARGET_BRANCH' into $BASE_BRANCH"
    write_merge_back_marker
    return 0
  fi

  if git -C "$REPO_ROOT" rev-parse -q --verify MERGE_HEAD >/dev/null; then
    echo "Git merge-back has conflicts. Delegating conflict resolution to $TOOL in the active merge state."
    return 1
  fi

  echo "Git merge-back failed before creating an active merge state."
  echo "Delegating to $TOOL to preserve local changes and start or complete merge-back."
  return 1
}
