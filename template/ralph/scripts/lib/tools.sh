#!/bin/bash

RALPH_LIB_DIR="${RALPH_LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
RALPH_STREAM_READER="$RALPH_LIB_DIR/stream-agent.mjs"

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

## Ralph Round Commit Contract

Every Ralph agent invocation is one self-contained round. If this round creates or modifies any intended repository artifact, stage and commit that artifact during this same round before returning control to \`ralph.sh\`. Do not leave intended output for a later story, finalization round, merge-back round, or consolidation round to commit.

- This contract applies to product code, tests, documentation, story state, PRD/progress records, merge resolutions, and design-ledger updates produced by the current round.
- Before finishing, inspect \`git status --short\` and verify that every intended artifact produced by this round is included in a commit.
- Never sweep unrelated pre-existing user changes into the round's commit. Leave them visible and report them separately.
- Runtime completion markers and explicitly designated temporary/diagnostic files are control-plane state, not repository artifacts; follow the round-specific prompt about whether they must remain uncommitted.
- Do not create an empty commit when the round produced no repository artifact or when an idempotent retry finds its artifacts already committed.
- If the full task is blocked after producing a safe, coherent partial result, commit that result as \`chore(ralph): checkpoint $RUN_ID_LABEL <round>\`, keep the story/round incomplete, and describe the blocker in progress. Do not commit broken code or temporary experiments.
- A round must not report success while any intended artifact it produced remains uncommitted.
EOF
}

run_selected_tool() {
  local run_cwd="$1"
  local prompt_file="$2"
  local stream_state_dir=""
  local activity_file=""
  local summary_file=""
  local diagnostic_file=""
  local output_fifo=""
  local stream_pid=""
  local stream_rate_limited="false"
  local tool_exit_code=0
  local tool_bin
  local node_bin
  local command_args=()

  LAST_MESSAGE=""
  OUTPUT=""
  LAST_TOOL_EXIT_CODE=0
  LAST_TOOL_SAW_COMPLETION="false"
  LAST_TOOL_DIAGNOSTIC_FILE=""

  node_bin="$(require_tool_command node node node.exe)" || return $?

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

  stream_state_dir=$(mktemp -d "${TMPDIR:-/tmp}/ralph-stream.XXXXXX")
  output_fifo="$stream_state_dir/events.fifo"
  activity_file="$stream_state_dir/activity"
  summary_file="$stream_state_dir/summary.json"
  diagnostic_file="$stream_state_dir/recent-events.jsonl"
  mkfifo "$output_fifo"

  ACTIVE_STREAM_STATE_DIR="$stream_state_dir"

  # Both CLIs emit one JSON event per line, covering full tool inputs, tool
  # results and usage metadata. Echoing that raw drowns out anything useful, so
  # stream-agent.mjs reduces it to a compact log on stderr and leaves a summary
  # behind for us. Ralph never keeps a second copy of the whole stream.
  #
  # The `cat` is load-bearing, not decoration. On Git Bash a mkfifo only behaves
  # when a Cygwin process owns the reader side, so cat reads the FIFO and hands
  # the events to node over an anonymous pipe, which a native node.exe can read.
  {
    cat < "$output_fifo" | "$node_bin" "$RALPH_STREAM_READER" \
      --tool "$TOOL" \
      --activity-file "$activity_file" \
      --summary-file "$summary_file" \
      --diagnostic-file "$diagnostic_file"
  } &
  stream_pid="$!"

  start_tracked_process "$run_cwd" "$prompt_file" "$output_fifo" "${command_args[@]}"
  wait_for_active_tool "$activity_file" counter || tool_exit_code=$?

  finalize_tool_cleanup "$run_cwd"

  ACTIVE_TOOL_PID=""
  ACTIVE_TOOL_PGID=""
  ACTIVE_TOOL_WINPID=""

  # The tool is gone, so the FIFO's writer is closed: cat reaches EOF and node
  # drains what is still buffered before writing its summary.
  wait "$stream_pid" 2>/dev/null || true

  if [[ -f "$summary_file" ]]; then
    LAST_TOOL_SAW_COMPLETION="$(jq -r '.sawCompletion // false' "$summary_file" 2>/dev/null || echo "false")"
    stream_rate_limited="$(jq -r '.rateLimited // false' "$summary_file" 2>/dev/null || echo "false")"
    OUTPUT="$(jq -r '.assistantText // ""' "$summary_file" 2>/dev/null || echo "")"
  else
    echo "Warning: the $TOOL stream reader wrote no summary; treating this invocation as failed." >&2
    if [[ "$tool_exit_code" -eq 0 ]]; then
      tool_exit_code=1
    fi
  fi

  if [[ "$TOOL" == "codex" ]]; then
    LAST_MESSAGE=$(cat "$LAST_MESSAGE_FILE" 2>/dev/null || true)
    rm -f "$LAST_MESSAGE_FILE"
  else
    LAST_MESSAGE="$OUTPUT"
  fi

  if [[ "$tool_exit_code" -ne 0 && -f "$diagnostic_file" ]]; then
    LAST_TOOL_DIAGNOSTIC_FILE="$diagnostic_file"
    echo "$TOOL failed; up to 100 recent raw events were saved for diagnosis: $diagnostic_file" >&2
  else
    rm -f "$diagnostic_file"
  fi

  # The .tmp siblings only survive a reader killed mid-write, but leaving one
  # behind would block the rmdir and strand the whole scratch dir.
  rm -f "$output_fifo" "$activity_file" "$activity_file.tmp" \
    "$summary_file" "$summary_file.tmp"
  rmdir "$stream_state_dir" 2>/dev/null || true
  ACTIVE_STREAM_STATE_DIR=""

  if [[ "$tool_exit_code" -eq "${RALPH_TOOL_TIMEOUT_EXIT_CODE:-124}" ]]; then
    echo ""
    echo "Ralph stopped $TOOL because the tool invocation timed out or went idle."
    echo "Adjust RALPH_TOOL_TIMEOUT_SECONDS or RALPH_TOOL_IDLE_TIMEOUT_SECONDS if this was expected."
    return "${RALPH_TOOL_TIMEOUT_EXIT_CODE:-124}"
  fi

  if [[ "$tool_exit_code" -ne 0 ]] \
    && { [[ "$stream_rate_limited" == "true" ]] || ralph_detected_rate_limit "$LAST_MESSAGE"; }; then
    echo ""
    echo "Ralph detected a 429/rate-limit response from $TOOL. Skipping remaining Ralph iterations."
    notify_ralph_rate_limited
    exit "$RALPH_RATE_LIMIT_EXIT_CODE"
  fi

  LAST_TOOL_EXIT_CODE="$tool_exit_code"

  # A clean exit code is not proof of a real turn: both CLIs can exit 0 after
  # their stream was cut short, which used to be indistinguishable from success.
  if [[ "$tool_exit_code" -ne 0 ]]; then
    echo "Warning: $TOOL exited with code $tool_exit_code." >&2
  elif [[ "$LAST_TOOL_SAW_COMPLETION" != "true" ]]; then
    echo "Warning: $TOOL exited cleanly but never reported a completed turn; counting this iteration as failed." >&2
    LAST_TOOL_EXIT_CODE=1
  elif [[ -z "$LAST_MESSAGE" ]]; then
    # Weak on its own: a turn can legitimately end on tool calls with no closing
    # message, so this stays a warning instead of a failure.
    echo "Warning: $TOOL completed its turn but produced no final message." >&2
  fi

  record_tool_outcome
  return 0
}

# Ralph's loop is meant to survive a bad iteration, so one failure only warns.
# A broken setup fails every iteration though, and without a counter that burns
# the entire run against the API for nothing.
record_tool_outcome() {
  local limit="${RALPH_MAX_CONSECUTIVE_FAILURES:-3}"

  [[ "$limit" =~ ^[0-9]+$ ]] || limit=3

  if [[ "${LAST_TOOL_EXIT_CODE:-0}" -eq 0 ]]; then
    CONSECUTIVE_TOOL_FAILURES=0
    return 0
  fi

  CONSECUTIVE_TOOL_FAILURES=$((${CONSECUTIVE_TOOL_FAILURES:-0} + 1))

  if [[ "$limit" -gt 0 && "$CONSECUTIVE_TOOL_FAILURES" -ge "$limit" ]]; then
    echo ""
    echo "Ralph stopping: $TOOL failed $CONSECUTIVE_TOOL_FAILURES times in a row."
    echo "Set RALPH_MAX_CONSECUTIVE_FAILURES=0 to keep going through failures."
    notify_ralph_needs_attention
    exit 1
  fi

  echo "Ralph tool failure $CONSECUTIVE_TOOL_FAILURES/$limit; continuing." >&2
  return 0
}

ralph_detected_rate_limit() {
  local text="$1"

  [[ -n "$text" ]] || return 1

  printf '%s\n' "$text" | grep -Eiq \
    '(^|[^[:digit:]])429([^[:digit:]]|$)|too many requests|rate[-_ ]?limit(ed|ing)?|quota exceeded'
}
