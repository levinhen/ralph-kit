#!/bin/bash

get_process_group() {
  local pid="$1"

  ps -o pgid= -p "$pid" 2>/dev/null | tr -d '[:space:]'
}

RALPH_PROCESS_GROUP="$(get_process_group "$$")"

start_tracked_process() {
  local run_cwd="$1"
  local prompt_file="$2"
  local output_fifo="$3"
  local started_with_new_session="false"
  shift 3

  if command -v perl >/dev/null 2>&1; then
    (
      cd "$run_cwd" \
        && exec perl -MPOSIX=setsid -e 'setsid() or die "setsid: $!"; exec @ARGV or die "exec: $!";' "$@" < "$prompt_file" > "$output_fifo" 2>&1
    ) &
    started_with_new_session="true"
  else
    (
      cd "$run_cwd" \
        && exec "$@" < "$prompt_file" > "$output_fifo" 2>&1
    ) &
  fi

  ACTIVE_TOOL_PID="$!"
  if [[ "$started_with_new_session" == "true" ]]; then
    ACTIVE_TOOL_PGID="$ACTIVE_TOOL_PID"
  else
    ACTIVE_TOOL_PGID="$(get_process_group "$ACTIVE_TOOL_PID")"
    if [[ -z "$ACTIVE_TOOL_PGID" || "$ACTIVE_TOOL_PGID" == "$RALPH_PROCESS_GROUP" ]]; then
      ACTIVE_TOOL_PGID=""
    fi
  fi
}

resolve_command_path() {
  local candidate

  for candidate in "$@"; do
    if command -v "$candidate" >/dev/null 2>&1; then
      command -v "$candidate"
      return 0
    fi
  done

  return 1
}

require_tool_command() {
  local tool_name="$1"
  shift
  local resolved

  if resolved="$(resolve_command_path "$@")"; then
    echo "$resolved"
    return 0
  fi

  echo "Error: Could not find executable for Ralph tool '$tool_name'." >&2
  echo "Looked for: $*" >&2
  echo "PATH: $PATH" >&2
  return 127
}

process_group_alive() {
  local pgid="$1"

  [[ -n "$pgid" ]] && kill -0 "-$pgid" 2>/dev/null
}

file_size_bytes() {
  local file_path="$1"

  if [[ ! -f "$file_path" ]]; then
    echo 0
    return
  fi

  wc -c < "$file_path" | tr -d '[:space:]'
}

positive_integer_or_zero() {
  local value="$1"

  [[ "$value" =~ ^[0-9]+$ ]]
}

wait_for_active_tool() {
  local output_file="$1"
  local timeout_seconds="${RALPH_TOOL_TIMEOUT_SECONDS:-0}"
  local idle_timeout_seconds="${RALPH_TOOL_IDLE_TIMEOUT_SECONDS:-360}"
  local start_time
  local last_activity_time
  local now
  local output_size
  local last_output_size
  local tool_status=0

  if ! positive_integer_or_zero "$timeout_seconds"; then
    timeout_seconds=0
  fi

  if ! positive_integer_or_zero "$idle_timeout_seconds"; then
    idle_timeout_seconds=360
  fi

  start_time="$(date +%s)"
  last_activity_time="$start_time"
  last_output_size="$(file_size_bytes "$output_file")"

  while kill -0 "$ACTIVE_TOOL_PID" 2>/dev/null; do
    sleep 2
    now="$(date +%s)"
    output_size="$(file_size_bytes "$output_file")"

    if [[ "$output_size" != "$last_output_size" ]]; then
      last_output_size="$output_size"
      last_activity_time="$now"
    fi

    if [[ "$timeout_seconds" -gt 0 && $((now - start_time)) -ge "$timeout_seconds" ]]; then
      echo "" >&2
      echo "Ralph tool invocation exceeded RALPH_TOOL_TIMEOUT_SECONDS=$timeout_seconds; stopping it." >&2
      terminate_active_tool
      wait "$ACTIVE_TOOL_PID" 2>/dev/null || true
      return "${RALPH_TOOL_TIMEOUT_EXIT_CODE:-124}"
    fi

    if [[ "$idle_timeout_seconds" -gt 0 && $((now - last_activity_time)) -ge "$idle_timeout_seconds" ]]; then
      echo "" >&2
      echo "Ralph tool invocation produced no output for RALPH_TOOL_IDLE_TIMEOUT_SECONDS=$idle_timeout_seconds; stopping it." >&2
      terminate_active_tool
      wait "$ACTIVE_TOOL_PID" 2>/dev/null || true
      return "${RALPH_TOOL_TIMEOUT_EXIT_CODE:-124}"
    fi
  done

  wait "$ACTIVE_TOOL_PID" || tool_status=$?
  return "$tool_status"
}

collect_descendant_pids() {
  local parent_pid="$1"
  local child_pid

  if ! command -v pgrep >/dev/null 2>&1; then
    return
  fi

  for child_pid in $(pgrep -P "$parent_pid" 2>/dev/null || true); do
    echo "$child_pid"
    collect_descendant_pids "$child_pid"
  done
}

terminate_active_tool() {
  local pgid="$ACTIVE_TOOL_PGID"
  local pid="$ACTIVE_TOOL_PID"
  local tee_pid="$ACTIVE_TOOL_TEE_PID"
  local descendant_pids=""
  local attempts=0

  if [[ -n "$pid" ]]; then
    descendant_pids="$(collect_descendant_pids "$pid")"
  fi

  if [[ -n "$pgid" ]]; then
    echo "Stopping active Ralph tool process group: $pgid" >&2
    kill -TERM "-$pgid" 2>/dev/null || true
    if [[ -n "$descendant_pids" ]]; then
      kill -TERM $descendant_pids 2>/dev/null || true
    fi
    while process_group_alive "$pgid" && [[ "$attempts" -lt 20 ]]; do
      sleep 0.1
      attempts=$((attempts + 1))
    done
    if process_group_alive "$pgid"; then
      echo "Active Ralph tool process group did not exit after TERM; sending KILL: $pgid" >&2
      kill -KILL "-$pgid" 2>/dev/null || true
      if [[ -n "$descendant_pids" ]]; then
        kill -KILL $descendant_pids 2>/dev/null || true
      fi
    fi
  elif [[ -n "$pid" ]]; then
    kill -TERM "$pid" 2>/dev/null || true
    if [[ -n "$descendant_pids" ]]; then
      kill -TERM $descendant_pids 2>/dev/null || true
    fi
  fi

  if [[ -n "$tee_pid" ]]; then
    kill "$tee_pid" 2>/dev/null || true
  fi
}
