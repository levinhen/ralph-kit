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

run_selected_tool() {
  local run_cwd="$1"
  local prompt_file="$2"
  local output_file
  local output_fifo
  local tool_exit_code=0
  local tool_bin
  local command_args=()

  LAST_MESSAGE=""
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
      --output-last-message "$LAST_MESSAGE_FILE" \
      -)
  fi

  output_file=$(mktemp)
  output_fifo=$(mktemp -u)
  mkfifo "$output_fifo"

  if [[ "$TOOL" == "claude" ]]; then
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
  else
    tee /dev/stderr < "$output_fifo" > "$output_file" &
  fi
  ACTIVE_TOOL_TEE_PID="$!"

  start_tracked_process "$run_cwd" "$prompt_file" "$output_fifo" "${command_args[@]}"
  wait_for_active_tool "$output_file" || tool_exit_code=$?

  finalize_tool_cleanup "$run_cwd"

  ACTIVE_TOOL_PID=""
  ACTIVE_TOOL_PGID=""
  ACTIVE_TOOL_WINPID=""

  wait "$ACTIVE_TOOL_TEE_PID" || true
  ACTIVE_TOOL_TEE_PID=""

  OUTPUT=$(cat "$output_file")
  rm -f "$output_file" "$output_fifo"

  if [[ "$TOOL" == "codex" ]]; then
    LAST_MESSAGE=$(cat "$LAST_MESSAGE_FILE" 2>/dev/null || true)
    rm -f "$LAST_MESSAGE_FILE"
  fi

  if [[ "$tool_exit_code" -eq "${RALPH_TOOL_TIMEOUT_EXIT_CODE:-124}" ]]; then
    echo ""
    echo "Ralph stopped $TOOL because the tool invocation timed out or went idle."
    echo "Adjust RALPH_TOOL_TIMEOUT_SECONDS or RALPH_TOOL_IDLE_TIMEOUT_SECONDS if this was expected."
    return "${RALPH_TOOL_TIMEOUT_EXIT_CODE:-124}"
  fi

  if [[ "$tool_exit_code" -ne 0 ]] \
    && { ralph_detected_rate_limit "$OUTPUT" \
      || { [[ "$TOOL" == "codex" ]] && ralph_detected_rate_limit "$LAST_MESSAGE"; }; }; then
    echo ""
    echo "Ralph detected a 429/rate-limit response from $TOOL. Skipping remaining Ralph iterations."
    notify_ralph_rate_limited
    exit "$RALPH_RATE_LIMIT_EXIT_CODE"
  fi

  return 0
}

ralph_detected_rate_limit() {
  local text="$1"

  [[ -n "$text" ]] || return 1

  printf '%s\n' "$text" | grep -Eiq \
    '(^|[^[:digit:]])429([^[:digit:]]|$)|too many requests|rate[-_ ]?limit(ed|ing)?|quota exceeded'
}
