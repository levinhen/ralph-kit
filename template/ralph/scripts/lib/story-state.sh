#!/bin/bash

ensure_progress_dir() {
  if [[ -z "$PROGRESS_DIR" || -z "$SHARED_MEMORY_FILE" ]]; then
    return
  fi

  mkdir -p "$PROGRESS_DIR"
  if [[ ! -f "$SHARED_MEMORY_FILE" ]]; then
    echo '[]' > "$SHARED_MEMORY_FILE"
  fi
}

story_progress_jsonl() {
  local story_id="$1"
  validate_story_id_for_file "$story_id"
  echo "$PROGRESS_DIR/$story_id.jsonl"
}

story_progress_jsonl_rel() {
  local story_id="$1"
  validate_story_id_for_file "$story_id"
  echo "$PROGRESS_REL_DIR/$story_id.jsonl"
}

validate_story_id_for_file() {
  local story_id="$1"

  if [[ ! "$story_id" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "Error: Story id '$story_id' cannot be used as a Ralph story filename." >&2
    exit 1
  fi
}

story_file_path() {
  local story_id="$1"

  validate_story_id_for_file "$story_id"
  echo "$STORIES_DIR/$story_id.json"
}

story_rel_path() {
  local story_id="$1"

  validate_story_id_for_file "$story_id"
  echo "$STORIES_REL_DIR/$story_id.json"
}

initialize_story_files() {
  local story_id
  local story_file
  local root_user_need

  mkdir -p "$STORIES_DIR"

  # The root-level `userNeed` (the business-language restatement of what the
  # user actually wants) is the single source of truth. Copy it into each
  # per-story file at split time so every memoryless iteration sees the big
  # picture from its own story file without reading the full PRD. A story that
  # already defines its own `userNeed` keeps it.
  root_user_need=$(jq -c '.userNeed // null' "$PRD_FILE" 2>/dev/null || echo "null")

  jq -r '.userStories[]?.id // empty' "$PRD_FILE" \
    | while IFS= read -r story_id; do
        story_id="${story_id//$'\r'/}"
        [[ -n "$story_id" ]] || continue
        validate_story_id_for_file "$story_id"
        story_file="$(story_file_path "$story_id")"
        if [[ -f "$story_file" ]]; then
          continue
        fi

        jq --arg story_id "$story_id" --argjson rootNeed "$root_user_need" '
          .userStories[]
          | select(.id == $story_id)
          | if ($rootNeed != null) and ((.userNeed // null) == null)
            then .userNeed = $rootNeed
            else .
            end
        ' "$PRD_FILE" > "$story_file"
      done
}

sync_story_files_to_prd() {
  local story_file
  local story_id
  local temp_file
  local next_file

  if [[ ! -d "$STORIES_DIR" ]]; then
    return
  fi

  temp_file=$(mktemp)
  cp "$PRD_FILE" "$temp_file"

  for story_file in "$STORIES_DIR"/*.json; do
    [[ -f "$story_file" ]] || continue
    story_id=$(jq -r '.id // empty' "$story_file" 2>/dev/null || echo "")
    story_id="${story_id//$'\r'/}"
    [[ -n "$story_id" ]] || continue

    next_file=$(mktemp)
    jq --arg story_id "$story_id" --slurpfile story "$story_file" '
      (.userStories[] | select(.id == $story_id)) = $story[0]
    ' "$temp_file" > "$next_file"
    mv "$next_file" "$temp_file"
  done

  if ! cmp -s "$temp_file" "$PRD_FILE"; then
    cp "$temp_file" "$PRD_FILE"
  fi
  rm -f "$temp_file"
}

sync_story_files_to_prd_after_iteration() {
  local before_head="$1"
  local after_head
  local staged_before

  sync_story_files_to_prd

  if git -C "$ACTIVE_WORKTREE" diff --quiet -- "$PRD_REL_PATH" \
    && git -C "$ACTIVE_WORKTREE" diff --cached --quiet -- "$PRD_REL_PATH"; then
    return
  fi

  after_head=$(git -C "$ACTIVE_WORKTREE" rev-parse --verify HEAD 2>/dev/null || echo "")
  if [[ -z "$before_head" || -z "$after_head" || "$before_head" == "$after_head" ]]; then
    echo "Ralph synced story files into $PRD_REL_PATH, but no new story commit was detected; leaving the PRD sync uncommitted."
    return
  fi

  staged_before=$(git -C "$ACTIVE_WORKTREE" diff --cached --name-only -- .)
  if [[ -n "$staged_before" ]]; then
    echo "Ralph synced story files into $PRD_REL_PATH, but the index already has staged changes; leaving the PRD sync unamended."
    return
  fi

  git -C "$ACTIVE_WORKTREE" add "$PRD_FILE"
  git -C "$ACTIVE_WORKTREE" commit --amend --no-edit
  echo "Ralph amended synced PRD state into the story commit."
}

initialize_ralph_story_state() {
  ensure_progress_dir
  initialize_story_files
  sync_story_files_to_prd
}

current_story_progress_json() {
  local story_id="$1"
  local memory_limit="${RALPH_SHARED_MEMORY_ITEMS:-40}"
  local story_limit="${RALPH_STORY_PROGRESS_RECORDS:-5}"
  local jsonl_file
  local story_records

  if [[ ! "$memory_limit" =~ ^[0-9]+$ ]]; then
    memory_limit=40
  fi
  if [[ ! "$story_limit" =~ ^[0-9]+$ ]]; then
    story_limit=5
  fi

  jsonl_file="$(story_progress_jsonl "$story_id")"
  if [[ -f "$jsonl_file" ]]; then
    story_records=$(tail -n "$story_limit" "$jsonl_file" | jq -s '.')
  else
    story_records='[]'
  fi

  jq -n \
    --slurpfile memory "$SHARED_MEMORY_FILE" \
    --argjson records "$story_records" \
    --argjson memory_limit "$memory_limit" \
    '{
      sharedMemory: (($memory[0] // [])[-$memory_limit:]),
      currentStoryRecords: $records
    }'
}

make_prompt_with_story_context() {
  local base_prompt="$1"
  local dest_prompt="$2"
  local story_id="$3"
  local story_file="$4"
  local story_rel_file
  local append_command

  story_rel_file="$(story_rel_path "$story_id")"
  local story_jsonl_rel
  story_jsonl_rel="$(story_progress_jsonl_rel "$story_id")"
  if [[ "$RUN_MODE" == "scoped" ]]; then
    append_command="bash ralph/scripts/append-progress-json.sh --run $RUN_ID --story $story_id --record path/to/progress-record.json"
  else
    append_command="bash ralph/scripts/append-progress-json.sh --legacy --story $story_id --record path/to/progress-record.json"
  fi

  cat "$base_prompt" > "$dest_prompt"
  cat <<EOF >> "$dest_prompt"

## Ralph Current Story Context

- Current story ID: \`$story_id\`
- Current story file path: \`$story_rel_file\`
- Shared memory path: \`$SHARED_MEMORY_REL_PATH\`
- Story progress file: \`$story_jsonl_rel\` (one JSON record per line, append-only)

Use the current story file as the authoritative story input for this iteration. Do not read the full PRD to choose work. Ralph will sync story files back into the run PRD after this iteration finishes.

Append story progress by writing one small progress-record JSON file and running:

\`\`\`bash
$append_command
\`\`\`

Do not edit \`$SHARED_MEMORY_REL_PATH\` or \`$story_jsonl_rel\` directly. The append command updates both safely.

### Current Story JSON

\`\`\`json
$(cat "$story_file")
\`\`\`

### Relevant Progress JSON (sliced)

Shared memory (most recent items) plus the most recent records for this story:

\`\`\`json
$(current_story_progress_json "$story_id")
\`\`\`
EOF
}
