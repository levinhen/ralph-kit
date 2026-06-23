#!/bin/bash

get_process_group() {
  local pid="$1"

  ps -o pgid= -p "$pid" 2>/dev/null | tr -d '[:space:]'
}

RALPH_PROCESS_GROUP="$(get_process_group "$$")"

case "$(uname -s 2>/dev/null)" in
  MINGW* | MSYS* | CYGWIN*) RALPH_IS_WINDOWS="true" ;;
  *) RALPH_IS_WINDOWS="false" ;;
esac

# On Windows/MSYS the tool we launch is a native process tree (cmd -> node ->
# ...), which POSIX process groups cannot reach. We instead track the Windows
# PID (winpid) of the launched process and kill the whole native tree with
# taskkill /T. MSYS exposes the mapping via /proc/<pid>/winpid.
msys_pid_to_winpid() {
  local pid="$1"
  local winpid=""
  local tries=0

  [[ -n "$pid" ]] || return 0

  while [[ -z "$winpid" && "$tries" -lt 10 ]]; do
    if [[ -r "/proc/$pid/winpid" ]]; then
      winpid="$(tr -d '[:space:]' < "/proc/$pid/winpid" 2>/dev/null || true)"
    fi
    [[ -n "$winpid" ]] && break
    sleep 0.05
    tries=$((tries + 1))
  done

  printf '%s' "$winpid"
}

windows_winpid_alive() {
  local winpid="$1"

  [[ -n "$winpid" ]] || return 1
  command -v tasklist >/dev/null 2>&1 || return 1
  MSYS2_ARG_CONV_EXCL='*' tasklist /FI "PID eq $winpid" 2>/dev/null | grep -q "$winpid"
}

# Kill a native Windows process tree by winpid. /T includes the child tree, /F
# forces termination. MSYS2_ARG_CONV_EXCL='*' stops MSYS from mangling the
# /PID, /T, /F switches into Unix paths.
windows_tree_kill() {
  local winpid="$1"

  [[ -n "$winpid" ]] || return 0
  command -v taskkill >/dev/null 2>&1 || return 0

  MSYS2_ARG_CONV_EXCL='*' taskkill /PID "$winpid" /T /F >/dev/null 2>&1 || true
}

# Safety-net sweep: kill any native process whose command line references the
# Ralph worktree path but is NOT part of Ralph's own process tree. Catches
# servers/watchers an agent fully detached (e.g. setsid/nohup) and forgot to
# stop. Scoped to a dedicated worktree path so it never matches the main repo.
windows_sweep_worktree_strays() {
  local worktree_msys="$1"
  local wt_win
  local self_winpid

  [[ "$RALPH_IS_WINDOWS" == "true" ]] || return 0
  [[ "${RALPH_DISABLE_WORKTREE_SWEEP:-0}" == "1" ]] && return 0
  [[ -n "$worktree_msys" ]] || return 0
  command -v powershell >/dev/null 2>&1 || return 0
  command -v cygpath >/dev/null 2>&1 || return 0

  wt_win="$(cygpath -w "$worktree_msys" 2>/dev/null || true)"
  [[ -n "$wt_win" ]] || return 0
  self_winpid="$(msys_pid_to_winpid "$$")"

  RALPH_WT_WIN="$wt_win" RALPH_SELF_WINPID="$self_winpid" MSYS2_ARG_CONV_EXCL='*' \
    powershell -NoProfile -ExecutionPolicy Bypass -Command '
      $wt = $env:RALPH_WT_WIN
      if (-not $wt) { exit }
      $self = [int]$env:RALPH_SELF_WINPID
      $wtL = $wt.ToLower()
      $wtAltL = ($wt -replace "\\", "/").ToLower()
      $all = Get-CimInstance Win32_Process
      $byId = @{}
      foreach ($p in $all) { $byId[[int]$p.ProcessId] = $p }
      $prot = New-Object "System.Collections.Generic.HashSet[int]"
      $cur = $self
      while ($cur -and $byId.ContainsKey($cur)) {
        [void]$prot.Add($cur)
        $cur = [int]$byId[$cur].ParentProcessId
      }
      $q = New-Object System.Collections.Queue
      [void]$q.Enqueue($self)
      while ($q.Count) {
        $id = [int]$q.Dequeue()
        foreach ($p in $all) {
          if ([int]$p.ParentProcessId -eq $id) {
            $c = [int]$p.ProcessId
            if ($prot.Add($c)) { [void]$q.Enqueue($c) }
          }
        }
      }
      foreach ($p in $all) {
        $cl = $p.CommandLine
        if (-not $cl) { continue }
        $clL = $cl.ToLower()
        if ($clL.Contains($wtL) -or $clL.Contains($wtAltL)) {
          $tpid = [int]$p.ProcessId
          if ($prot.Contains($tpid)) { continue }
          try {
            Stop-Process -Id $tpid -Force -ErrorAction Stop
            [Console]::Error.WriteLine("Ralph swept stray worktree process: pid $tpid ($($p.Name))")
          } catch {}
        }
      }
    ' 2>&1 || true
}

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

  ACTIVE_TOOL_WINPID=""
  if [[ "$RALPH_IS_WINDOWS" == "true" ]]; then
    ACTIVE_TOOL_WINPID="$(msys_pid_to_winpid "$ACTIVE_TOOL_PID")"
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

  if [[ "$RALPH_IS_WINDOWS" == "true" ]]; then
    local winpid="$ACTIVE_TOOL_WINPID"
    if [[ -z "$winpid" && -n "$pid" ]]; then
      winpid="$(msys_pid_to_winpid "$pid")"
    fi
    if [[ -n "$winpid" ]]; then
      echo "Stopping active Ralph tool process tree (winpid $winpid)" >&2
      windows_tree_kill "$winpid"
    fi
    # Fall back to an MSYS-level signal for anything cygwin still tracks.
    [[ -n "$pid" ]] && kill -TERM "$pid" 2>/dev/null || true
    if [[ -n "$tee_pid" ]]; then
      kill "$tee_pid" 2>/dev/null || true
    fi
    return 0
  fi

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

# Run after a tool invocation returns. Reaps any process tree the tool left
# behind, then (on Windows, for a dedicated worktree) sweeps detached strays
# whose command line references the worktree. Safe to call when nothing leaked.
finalize_tool_cleanup() {
  local run_cwd="$1"

  if [[ -n "$ACTIVE_TOOL_PID" ]] && kill -0 "$ACTIVE_TOOL_PID" 2>/dev/null; then
    echo "Ralph tool returned but left its process tree running; stopping it." >&2
    terminate_active_tool
  elif [[ "$RALPH_IS_WINDOWS" == "true" ]] \
    && [[ -n "$ACTIVE_TOOL_WINPID" ]] && windows_winpid_alive "$ACTIVE_TOOL_WINPID"; then
    echo "Ralph tool returned but left a native process tree running; stopping it." >&2
    windows_tree_kill "$ACTIVE_TOOL_WINPID"
  elif [[ "$RALPH_IS_WINDOWS" != "true" ]] \
    && [[ -n "$ACTIVE_TOOL_PGID" ]] && process_group_alive "$ACTIVE_TOOL_PGID"; then
    echo "Ralph tool returned but left process group running; stopping it: $ACTIVE_TOOL_PGID" >&2
    terminate_active_tool
  fi

  # Detached servers escape the tree; sweep them by worktree path. Only for a
  # dedicated worktree (never the main repo, which would be far too broad).
  if [[ "$RALPH_IS_WINDOWS" == "true" && -n "$run_cwd" && "$run_cwd" != "$REPO_ROOT" ]]; then
    windows_sweep_worktree_strays "$run_cwd"
  fi
}
