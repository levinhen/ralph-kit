#!/bin/bash

resolve_tool_prompt() {
  local scope="$1"

  case "$TOOL" in
    claude)
      if [[ "$scope" == "root" ]]; then
        echo "$ROOT_CLAUDE_PROMPT_FILE"
      else
        echo "$CLAUDE_PROMPT_FILE"
      fi
      ;;
    codex)
      if [[ "$scope" == "root" ]]; then
        echo "$ROOT_CODEX_PROMPT_FILE"
      else
        echo "$CODEX_PROMPT_FILE"
      fi
      ;;
  esac
}

make_prompt_with_run_context() {
  local base_prompt="$1"
  local dest_prompt="$2"

  cat "$base_prompt" > "$dest_prompt"
  cat <<EOF >> "$dest_prompt"

## Ralph Run Context

- Run mode: \`$RUN_MODE\`
- Run ID: \`$RUN_ID_LABEL\`
- PRD path: \`$PRD_REL_PATH\`
- Progress log path: \`$PROGRESS_REL_PATH\`
- Progress dir: \`$PROGRESS_REL_DIR\`
- Shared memory path: \`$SHARED_MEMORY_REL_PATH\`
- Story progress files: \`$PROGRESS_REL_DIR/<storyId>.jsonl\` (one JSON record per line, append-only)
- Story files dir: \`$STORIES_REL_DIR\`
- State path: \`$STATE_REL_PATH\`
- Target branch: \`$TARGET_BRANCH\`
- Base branch: \`$BASE_BRANCH\`
- Ralph worktree: \`$ACTIVE_WORKTREE\`
- Base repo root: \`$REPO_ROOT\`

Use the story, PRD, and progress paths from this context for all Ralph state reads and writes. Do not fall back to \`ralph/prd.json\`, \`ralph/progress.txt\`, or any legacy \`ralph/progress.json\` when this context gives run-scoped paths.
EOF
}

stream_codex_json() {
  local state_dir="$1"
  local status_file="$state_dir/status"
  local activity_file="$state_dir/activity"
  local display_fifo="$state_dir/display.fifo"
  local diagnostic_file="$2"
  local ring_limit=100
  local ring_index=0
  local ring_count=0
  local event_count=0
  local line
  local tool_status
  local start_index
  local current_index
  local i
  local display_pid
  local -a recent_events

  mkfifo "$display_fifo"

  # Keep JSON parsing in one long-lived jq process. Raw events reach it only
  # through this FIFO; they are never tee'd or redirected to a regular file.
  jq -rR --unbuffered '
    def error_text($fallback):
      (.message // (
        .error
        | if type == "object" then (.message // .) else . end
      ) // $fallback | tostring);

    . as $line
    | (try fromjson catch null) as $event
    | if $event == null then
        $line
      elif $event.type == "thread.started" then
        "[codex session: \($event.thread_id // "?")]"
      elif $event.type == "item.started" and $event.item.type == "command_execution" then
        "· " + (($event.item.command // "command") | tostring)
      elif $event.type == "item.started" and $event.item.type == "mcp_tool_call" then
        "· " + ([
          $event.item.server,
          $event.item.tool,
          $event.item.name
        ] | map(select(. != null and . != "")) | map(tostring) | join("."))
      elif $event.type == "item.started" and $event.item.type == "web_search" then
        "· web search"
      elif $event.type == "item.completed" and $event.item.type == "agent_message" then
        ($event.item.text // empty)
      elif $event.type == "item.completed" and $event.item.type == "file_change" then
        "· file changes"
      elif $event.type == "error" then
        "[error] " + ($event | error_text("unknown error"))
      elif $event.type == "turn.failed" then
        "[failed] " + ($event | error_text("turn failed"))
      elif $event.type == "turn.completed" then
        "[done]"
      else empty end
  ' < "$display_fifo" >&2 &
  display_pid="$!"
  exec 7> "$display_fifo"

  while IFS= read -r line || [[ -n "$line" ]]; do
    recent_events[$ring_index]="$line"
    ring_index=$(((ring_index + 1) % ring_limit))
    if [[ "$ring_count" -lt "$ring_limit" ]]; then
      ring_count=$((ring_count + 1))
    fi

    event_count=$((event_count + 1))
    printf '%s\n' "$event_count" > "$activity_file"
    printf '%s\n' "$line" >&7 || true
  done

  exec 7>&-
  wait "$display_pid" || true

  # The producer exit status arrives only after its stdout reaches EOF. This
  # lets the ring remain memory-only unless the Codex invocation failed.
  while [[ ! -s "$status_file" ]]; do
    sleep 0.05
  done
  tool_status="$(tr -d '[:space:]' < "$status_file")"

  if [[ "$tool_status" != "0" ]]; then
    if [[ "$ring_count" -lt "$ring_limit" ]]; then
      start_index=0
    else
      start_index="$ring_index"
    fi

    : > "$diagnostic_file"
    i=0
    while [[ "$i" -lt "$ring_count" ]]; do
      current_index=$(((start_index + i) % ring_limit))
      printf '%s\n' "${recent_events[$current_index]}" >> "$diagnostic_file"
      i=$((i + 1))
    done
  fi
}

finish_codex_json_stream() {
  local tool_status="$1"
  local stream_pid="$ACTIVE_CODEX_STREAM_PID"
  local state_dir="$ACTIVE_CODEX_STREAM_STATE_DIR"
  local diagnostic_file="$ACTIVE_CODEX_DIAGNOSTIC_FILE"

  [[ -n "$stream_pid" && -n "$state_dir" ]] || return 0

  printf '%s\n' "$tool_status" > "$state_dir/status"
  wait "$stream_pid" || true

  LAST_CODEX_DIAGNOSTIC_FILE=""
  if [[ "$tool_status" != "0" && -f "$diagnostic_file" ]]; then
    LAST_CODEX_DIAGNOSTIC_FILE="$diagnostic_file"
    echo "Codex failed; up to 100 recent raw events were saved for diagnosis: $diagnostic_file" >&2
  fi

  rm -f "$state_dir/events.fifo" "$state_dir/display.fifo" \
    "$state_dir/activity" "$state_dir/status"
  rmdir "$state_dir" 2>/dev/null || true

  ACTIVE_CODEX_STREAM_PID=""
  ACTIVE_CODEX_STREAM_STATE_DIR=""
  ACTIVE_CODEX_DIAGNOSTIC_FILE=""
}

run_selected_tool() {
  local run_cwd="$1"
  local prompt_file="$2"
  local output_file=""
  local output_fifo=""
  local activity_path=""
  local activity_mode="size"
  local stream_state_dir=""
  local tool_exit_code=0
  local tool_bin
  local command_args=()

  LAST_MESSAGE=""
  LAST_CODEX_DIAGNOSTIC_FILE=""
  if [[ "$TOOL" == "claude" ]]; then
    tool_bin="$(require_tool_command "$TOOL" claude claude.cmd)" || return $?
    command_args=("$tool_bin" --dangerously-skip-permissions --print --verbose --output-format stream-json)
  else
    LAST_MESSAGE_FILE=$(mktemp)
    tool_bin="$(require_tool_command "$TOOL" codex codex.cmd)" || return $?
    command_args=("$tool_bin" exec \
      --cd "$run_cwd" \
      --dangerously-bypass-approvals-and-sandbox \
      --skip-git-repo-check \
      --json \
      --output-last-message "$LAST_MESSAGE_FILE" \
      -)
  fi

  if [[ "$TOOL" == "claude" ]]; then
    output_file=$(mktemp)
    output_fifo=$(mktemp -u)
    mkfifo "$output_fifo"
    activity_path="$output_file"

    # claude is invoked with --output-format stream-json, which emits one JSON
    # event per line covering full tool inputs, tool results, usage metadata,
    # etc. Echoing all of that to the terminal drowns out what's interesting,
    # so we keep the raw NDJSON in $output_file (still needed for rate-limit
    # detection on $OUTPUT) and only surface a compact stream to stderr:
    #   - assistant text deltas as they arrive
    #   - one "· <tool>" marker per tool_use
    #   - a "[done: <subtype>]" line on the final result event
    # Anything jq cannot parse is forwarded verbatim so startup/error lines
    # printed by the claude CLI itself still reach the terminal.
    tee >(jq -rR --unbuffered '
            . as $line
            | (try fromjson catch null) as $event
            | if $event == null then
                $line
              elif $event.type == "assistant" then
                ($event.message.content[]?
                  | if .type == "text" then .text
                    elif .type == "tool_use" then "· " + .name
                    else empty end)
              elif $event.type == "result" then
                "[done: \($event.subtype // "?")]"
              else empty end
          ' >&2) < "$output_fifo" > "$output_file" &
    ACTIVE_TOOL_TEE_PID="$!"
  else
    # Codex keeps its normal persisted session because we deliberately do not
    # pass --ephemeral. Ralph does not keep a second copy of the JSONL stream.
    stream_state_dir=$(mktemp -d "${TMPDIR:-/tmp}/ralph-codex-stream.XXXXXX")
    output_fifo="$stream_state_dir/events.fifo"
    mkfifo "$output_fifo"
    activity_path="$stream_state_dir/activity"
    activity_mode="counter"

    ACTIVE_CODEX_STREAM_STATE_DIR="$stream_state_dir"
    ACTIVE_CODEX_DIAGNOSTIC_FILE="$stream_state_dir/recent-events.jsonl"
    stream_codex_json "$stream_state_dir" "$ACTIVE_CODEX_DIAGNOSTIC_FILE" < "$output_fifo" &
    ACTIVE_CODEX_STREAM_PID="$!"
  fi

  start_tracked_process "$run_cwd" "$prompt_file" "$output_fifo" "${command_args[@]}"
  wait_for_active_tool "$activity_path" "$activity_mode" || tool_exit_code=$?

  finalize_tool_cleanup "$run_cwd"

  ACTIVE_TOOL_PID=""
  ACTIVE_TOOL_PGID=""
  ACTIVE_TOOL_WINPID=""

  if [[ "$TOOL" == "codex" ]]; then
    finish_codex_json_stream "$tool_exit_code"
    LAST_MESSAGE=$(cat "$LAST_MESSAGE_FILE" 2>/dev/null || true)
    rm -f "$LAST_MESSAGE_FILE"
    OUTPUT=""
  else
    wait "$ACTIVE_TOOL_TEE_PID" || true
    ACTIVE_TOOL_TEE_PID=""
    OUTPUT=$(cat "$output_file")
    rm -f "$output_file" "$output_fifo"
  fi

  if [[ "$tool_exit_code" -eq "${RALPH_TOOL_TIMEOUT_EXIT_CODE:-124}" ]]; then
    echo ""
    echo "Ralph stopped $TOOL because the tool invocation timed out or went idle."
    echo "Adjust RALPH_TOOL_TIMEOUT_SECONDS or RALPH_TOOL_IDLE_TIMEOUT_SECONDS if this was expected."
    return "${RALPH_TOOL_TIMEOUT_EXIT_CODE:-124}"
  fi

  if [[ "$tool_exit_code" -ne 0 ]] \
    && { { [[ "$TOOL" == "claude" ]] && ralph_detected_rate_limit "$OUTPUT"; } \
      || { [[ "$TOOL" == "codex" ]] && ralph_detected_rate_limit_file "$LAST_CODEX_DIAGNOSTIC_FILE"; } \
      || { [[ "$TOOL" == "codex" ]] && ralph_detected_rate_limit "$LAST_MESSAGE"; }; }; then
    echo ""
    echo "Ralph detected a 429/rate-limit response from $TOOL. Skipping remaining Ralph iterations."
    notify_ralph_rate_limited
    exit "$RALPH_RATE_LIMIT_EXIT_CODE"
  fi

  return 0
}

ralph_detected_rate_limit_file() {
  local file_path="$1"

  [[ -n "$file_path" && -f "$file_path" ]] || return 1

  grep -Eiq \
    '(^|[^[:digit:]])429([^[:digit:]]|$)|too many requests|rate[-_ ]?limit(ed|ing)?|quota exceeded' \
    "$file_path"
}

ralph_detected_rate_limit() {
  local text="$1"

  [[ -n "$text" ]] || return 1

  printf '%s\n' "$text" | grep -Eiq \
    '(^|[^[:digit:]])429([^[:digit:]]|$)|too many requests|rate[-_ ]?limit(ed|ing)?|quota exceeded'
}
