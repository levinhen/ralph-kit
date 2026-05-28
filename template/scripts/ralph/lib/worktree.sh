#!/bin/bash

find_worktree_for_branch() {
  local branch="$1"
  git -C "$REPO_ROOT" worktree list --porcelain | awk -v target="refs/heads/$branch" '
    /^worktree / { path = substr($0, 10) }
    /^branch / && $2 == target { print path; exit }
  '
}

require_git_base() {
  if ! git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "Error: Ralph requires a Git repository at $REPO_ROOT"
    echo "Initialize and commit a base first, for example:"
    echo "  git -C \"$REPO_ROOT\" init -b main"
    echo "  git -C \"$REPO_ROOT\" add ."
    echo "  git -C \"$REPO_ROOT\" commit -m \"Initial Ralph workspace\""
    exit 1
  fi

  if ! git -C "$REPO_ROOT" rev-parse --verify HEAD >/dev/null 2>&1; then
    echo "Error: Ralph requires at least one Git commit in $REPO_ROOT"
    echo "Create the base commit before starting Ralph:"
    echo "  git -C \"$REPO_ROOT\" add ."
    echo "  git -C \"$REPO_ROOT\" commit -m \"Initial Ralph workspace\""
    exit 1
  fi
}

copy_file_if_exists() {
  local source="$1"
  local dest="$2"

  if [[ ! -f "$source" ]]; then
    return
  fi

  if [[ "$source" == "$dest" ]]; then
    return
  fi

  mkdir -p "$(dirname "$dest")"
  cp "$source" "$dest"
}

copy_file_if_missing() {
  local source="$1"
  local dest="$2"

  if [[ -f "$dest" ]]; then
    return
  fi

  copy_file_if_exists "$source" "$dest"
}

copy_dir_if_missing() {
  local source="$1"
  local dest="$2"

  if [[ ! -d "$source" || -d "$dest" ]]; then
    return
  fi

  mkdir -p "$(dirname "$dest")"
  cp -R "$source" "$dest"
}

copy_state_if_missing_base() {
  local source="$1"
  local dest="$2"
  local source_base
  local dest_base

  if [[ ! -f "$source" ]]; then
    return
  fi

  if [[ ! -f "$dest" ]]; then
    copy_file_if_exists "$source" "$dest"
    return
  fi

  source_base=$(jq -r '.baseBranch // empty' "$source" 2>/dev/null || echo "")
  dest_base=$(jq -r '.baseBranch // empty' "$dest" 2>/dev/null || echo "")

  if [[ -n "$source_base" && -z "$dest_base" ]]; then
    copy_file_if_exists "$source" "$dest"
  fi
}

acquire_dir_lock() {
  local lock_dir="$1"
  local lock_label="$2"
  local stale_pid

  mkdir -p "$LOCK_ROOT"

  while ! mkdir "$lock_dir" 2>/dev/null; do
    stale_pid="$(cat "$lock_dir/pid" 2>/dev/null || true)"
    if [[ -n "$stale_pid" ]] && ! kill -0 "$stale_pid" 2>/dev/null; then
      rm -f "$lock_dir/pid"
      rmdir "$lock_dir" 2>/dev/null || true
      continue
    fi

    echo "Waiting for $lock_label lock: $lock_dir"
    sleep 5
  done

  echo "$$" > "$lock_dir/pid"
}

release_dir_lock() {
  local lock_dir="$1"

  if [[ -z "$lock_dir" || ! -d "$lock_dir" ]]; then
    return
  fi

  rm -f "$lock_dir/pid"
  rmdir "$lock_dir" 2>/dev/null || true
}
