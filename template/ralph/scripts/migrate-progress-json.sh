#!/bin/bash
# One-shot migration: split each run's aggregated progress.json into:
#   <run>/progress/shared-memory.json (JSON array)
#   <run>/progress/<storyId>.jsonl    (one JSON record per line)
#
# The source progress.json is removed after a successful split.

set -e

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/run-context.sh"

split_one() {
  local source_json="$1"
  local progress_dir
  progress_dir="$(dirname "$source_json")/progress"

  if [[ ! -f "$source_json" ]]; then
    return
  fi

  echo "Migrating: $source_json"
  mkdir -p "$progress_dir"

  jq -c '.sharedMemory // []' "$source_json" > "$progress_dir/shared-memory.json"

  # For each story id, write each record as one compact line.
  local migrated_any="false"
  while IFS= read -r story_id; do
    story_id="${story_id//$'\r'/}"
    story_id="${story_id//$'\n'/}"
    [[ -n "$story_id" ]] || continue
    if ! ralph_story_id_is_valid "$story_id"; then
      echo "  Skipping invalid story id: $story_id" >&2
      continue
    fi
    local target="$progress_dir/$story_id.jsonl"
    : > "$target"
    jq -c --arg id "$story_id" '.stories[$id][]?' "$source_json" >> "$target"
    local count
    count=$(wc -l < "$target" | tr -d '[:space:]')
    echo "  $story_id.jsonl ($count records)"
    migrated_any="true"
  done < <(jq -r '.stories | keys[]?' "$source_json")

  if [[ "$migrated_any" != "true" ]] && [[ "$(jq -r '.stories | length' "$source_json")" -gt 0 ]]; then
    echo "  Refusing to remove $source_json: no story records were migrated." >&2
    return 1
  fi

  rm "$source_json"
  echo "  Removed: $source_json"
}

# Scoped runs.
for run_dir in "$RALPH_ROOT/runs"/*/; do
  [[ -d "$run_dir" ]] || continue
  split_one "$run_dir/progress.json"
done

# Legacy root.
split_one "$RALPH_ROOT/progress.json"

echo "Migration complete."
