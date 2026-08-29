#!/bin/bash
# Ralph Orchestrator - Run multiple Ralph runs in stages or as a dependency graph.
#
# Usage:
#   ./orchestrate.sh [--tool claude|codex|pi] [--plan "1 > 2,3 > 4" | --graph]
#                    [--dry-run]
#
# Modes:
#   stage  A hand-typed plan orders the runs (--plan / RALPH_PLAN, or the
#          interactive prompt).
#   graph  --graph, or automatically when any incomplete run declares
#          `dependsOnRuns`. The order is derived from those edges instead of
#          being typed out.
#
# Plan syntax (stage mode):
#   ','  parallel within the same stage
#   '>'  sequential across stages
#   Whitespace is ignored. Example: "1 > 2,3 > 4" runs run #1 first, then #2
#   and #3 in parallel, then #4.
#
# Behavior (stage mode):
#   - Lists incomplete runs (sorted by run_id), assigns each a number, and
#     prompts you for a plan. Numbers are stable across invocations as long
#     as the set of incomplete runs is unchanged.
#   - Stages run in order. Within a stage, all runs launch in parallel and
#     the orchestrator waits for all of them before evaluating the stage.
#   - If any run in a stage fails, the stage finishes its sibling runs first,
#     then the orchestrator stops (later stages are skipped).
#   - If any run detects a 429/rate-limit response, the orchestrator stops and
#     skips later stages.
#   - Parallel-run output is redirected to per-run log files; single-run
#     stages stream directly to the terminal.
#
# Behavior (graph mode):
#   - Nodes are the incomplete runs; edges come from each run's `dependsOnRuns`.
#     A dependency that already finished and merged back (or was archived) is
#     dropped. A dependency naming no known run is a hard error, as is a cycle.
#   - Scheduling is event-driven, not wave-locked: every run whose graph
#     dependencies have succeeded starts immediately, so a run never waits on
#     an unrelated sibling. Every run logs to its own file.
#   - A failed run blocks its transitive downstream; unrelated runs keep going.
#   - A 429/rate-limit response stops the in-flight runs and the orchestrator.
#   - --dry-run prints the edges and a topological wave preview, then exits.
#
# Environment:
#   RALPH_PLAN     Default plan string (overridden by --plan, ignored by --graph).
#   RALPH_NOTIFY=0 Disable Ralph's per-run desktop notifications.

set -e

TOOL="${RALPH_TOOL:-codex}"
PLAN_INPUT="${RALPH_PLAN:-}"
PLAN_FROM_FLAG="false"
GRAPH_FLAG="false"
DRY_RUN="false"
RALPH_RATE_LIMIT_EXIT_CODE=75

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tool)
      TOOL="$2"
      shift 2
      ;;
    --tool=*)
      TOOL="${1#*=}"
      shift
      ;;
    --plan)
      PLAN_INPUT="$2"
      PLAN_FROM_FLAG="true"
      shift 2
      ;;
    --plan=*)
      PLAN_INPUT="${1#*=}"
      PLAN_FROM_FLAG="true"
      shift
      ;;
    --graph)
      GRAPH_FLAG="true"
      shift
      ;;
    --dry-run)
      DRY_RUN="true"
      shift
      ;;
    -h|--help)
      sed -n '2,47p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      # ralph.sh no longer takes a max_iterations budget; swallow the old
      # positional argument here so existing wrappers keep working.
      if [[ "$1" =~ ^[0-9]+$ ]]; then
        echo "Warning: the max_iterations argument ('$1') is obsolete and ignored." >&2
      else
        echo "Error: Unknown argument '$1'" >&2
        exit 1
      fi
      shift
      ;;
  esac
done

if [[ "$TOOL" != "claude" && "$TOOL" != "codex" && "$TOOL" != "pi" ]]; then
  echo "Error: Invalid tool '$TOOL'. Must be 'claude', 'codex', or 'pi'." >&2
  exit 1
fi

if [[ "$GRAPH_FLAG" == "true" && "$PLAN_FROM_FLAG" == "true" ]]; then
  echo "Error: --plan and --graph are mutually exclusive." >&2
  exit 1
fi

# An inherited RALPH_PLAN is only a default; an explicit --graph outranks it.
if [[ "$GRAPH_FLAG" == "true" ]]; then
  PLAN_INPUT=""
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RALPH_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$RALPH_ROOT/.." && pwd)"
RUNS_ROOT="$RALPH_ROOT/runs"
RALPH_SCRIPT="$SCRIPT_DIR/ralph.sh"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"

if [[ ! -x "$RALPH_SCRIPT" ]]; then
  echo "Error: Cannot execute $RALPH_SCRIPT" >&2
  exit 1
fi

# --- Run discovery (shared with ralph.sh / lint-prd.sh) -----------------------

# run_prd_all_passed, run_merge_back_complete, run_dependency_satisfied.
# shellcheck source=lib/run-deps.sh
. "$SCRIPT_DIR/lib/run-deps.sh"

run_is_complete() {
  local run_dir="$1"
  run_prd_all_passed "$run_dir/prd.json" \
    && run_merge_back_complete "$run_dir" "$REPO_ROOT"
}

discover_incomplete_runs() {
  if [[ ! -d "$RUNS_ROOT" ]]; then
    return
  fi

  find "$RUNS_ROOT" -mindepth 2 -maxdepth 2 -type f -name prd.json -print \
    | while IFS= read -r prd_file; do
        run_dir="$(dirname "$prd_file")"
        if ! run_is_complete "$run_dir"; then
          basename "$run_dir"
        fi
      done \
    | sort
}

# --- Gather incomplete runs ---------------------------------------------------

INCOMPLETE_RUNS=()
while IFS= read -r r; do
  INCOMPLETE_RUNS+=("$r")
done < <(discover_incomplete_runs)

TOTAL_RUNS="${#INCOMPLETE_RUNS[@]}"

if [[ "$TOTAL_RUNS" -eq 0 ]]; then
  echo "No incomplete Ralph runs found."
  exit 0
fi

echo "Incomplete runs:"
i=0
while [[ $i -lt $TOTAL_RUNS ]]; do
  printf "  %2d  %s\n" "$((i + 1))" "${INCOMPLETE_RUNS[$i]}"
  i=$((i + 1))
done
echo ""

# --- Mode selection -----------------------------------------------------------

# True when any incomplete run declares at least one `dependsOnRuns` entry. Such
# a run already carries the ordering a stage plan would only restate by hand, so
# it is taken as the signal to schedule from the graph instead of prompting.
graph_edges_declared() {
  local idx=0 run_id first_dep
  while [[ $idx -lt $TOTAL_RUNS ]]; do
    run_id="${INCOMPLETE_RUNS[$idx]}"
    first_dep="$(jq -r '
      (.dependsOnRuns // [])
      | if type == "array" then .[] else empty end
      | select(type == "string")
    ' "$RUNS_ROOT/$run_id/prd.json" 2>/dev/null | head -1)"
    if [[ -n "$first_dep" ]]; then
      return 0
    fi
    idx=$((idx + 1))
  done
  return 1
}

MODE="stage"
if [[ -n "$PLAN_INPUT" ]]; then
  MODE="stage"
elif [[ "$GRAPH_FLAG" == "true" ]]; then
  MODE="graph"
elif graph_edges_declared; then
  MODE="graph"
  echo "Found dependsOnRuns edges: scheduling as a dependency graph (no --plan given)."
fi

# --- Execution plumbing (shared by both modes) --------------------------------

ORCH_PIDS=()

terminate_orchestrated_runs() {
  if [[ ${#ORCH_PIDS[@]} -gt 0 ]]; then
    echo ""
    echo "Stopping in-flight Ralph runs: ${ORCH_PIDS[*]}" >&2
    kill -TERM "${ORCH_PIDS[@]}" 2>/dev/null || true
    wait "${ORCH_PIDS[@]}" 2>/dev/null || true
  fi
}

cleanup_on_signal() {
  terminate_orchestrated_runs
  exit 130
}
trap cleanup_on_signal INT TERM

# --- Graph mode ---------------------------------------------------------------

# Per-run state lives in indexed arrays sharing INCOMPLETE_RUNS' indices - bash
# 3.2 (the macOS default) has no associative arrays. GRAPH_DEPS holds a
# space-separated list of dependency *indices* and is expanded unquoted on
# purpose; the values are always integers.
GRAPH_DEPS=()       # intra-graph dependency indices
GRAPH_MET_DEPS=()   # dependency ids already merged back or archived (display)
GRAPH_STATE=()      # pending | running | succeeded | failed | stopped | blocked
GRAPH_PID=()
GRAPH_LOG=()
GRAPH_RC=()
GRAPH_BLOCKER=()    # id of the failed ancestor that blocked this run
GRAPH_WAVE=()       # topological wave, 0 until assigned

graph_index_of_run() {
  local needle="$1" idx=0
  while [[ $idx -lt $TOTAL_RUNS ]]; do
    if [[ "${INCOMPLETE_RUNS[$idx]}" == "$needle" ]]; then
      printf '%s\n' "$idx"
      return 0
    fi
    idx=$((idx + 1))
  done
  return 1
}

# Read `dependsOnRuns` for every scheduled run and sort each entry into one of
# three buckets: an edge to another run scheduled here, a dependency that has
# already landed (dropped - there is nothing left to wait for), or a reference
# nothing can satisfy (fatal). Discovery already covers every run dir that is
# not complete, so "neither scheduled nor satisfied" can only be a bad id.
graph_build() {
  local idx=0 run_id dep dep_idx seen bad=0

  while [[ $idx -lt $TOTAL_RUNS ]]; do
    run_id="${INCOMPLETE_RUNS[$idx]}"
    GRAPH_DEPS[$idx]=""
    GRAPH_MET_DEPS[$idx]=""
    GRAPH_STATE[$idx]="pending"
    GRAPH_PID[$idx]=""
    GRAPH_LOG[$idx]=""
    GRAPH_RC[$idx]=0
    GRAPH_BLOCKER[$idx]=""
    GRAPH_WAVE[$idx]=0
    seen=" "

    while IFS= read -r dep; do
      [[ -n "$dep" ]] || continue
      case "$seen" in
        *" $dep "*) continue ;;
      esac
      seen="$seen$dep "

      if dep_idx="$(graph_index_of_run "$dep")"; then
        GRAPH_DEPS[$idx]="${GRAPH_DEPS[$idx]} $dep_idx"
      elif run_dependency_satisfied "$RALPH_ROOT" "$REPO_ROOT" "$dep"; then
        GRAPH_MET_DEPS[$idx]="${GRAPH_MET_DEPS[$idx]} $dep"
      else
        echo "Error: run '$run_id' depends on '$dep', which is neither a run scheduled here nor a finished/archived run." >&2
        bad=1
      fi
    done < <(jq -r '
      (.dependsOnRuns // [])
      | if type == "array" then .[] else empty end
      | select(type == "string")
    ' "$RUNS_ROOT/$run_id/prd.json" 2>/dev/null || true)

    idx=$((idx + 1))
  done

  if [[ "$bad" -eq 1 ]]; then
    echo "Fix those dependsOnRuns references first. No runs were started." >&2
    return 1
  fi
  return 0
}

# Kahn peeling: each pass collects every unassigned run whose dependencies all
# have a wave, then assigns them together, so runs in the same pass never see
# each other. Whatever is still unassigned when a pass adds nothing sits in - or
# downstream of - a cycle.
graph_assign_waves() {
  local wave=0 idx dep ready batch cyclic="" cid

  while true; do
    wave=$((wave + 1))
    batch=""
    idx=0
    while [[ $idx -lt $TOTAL_RUNS ]]; do
      if [[ "${GRAPH_WAVE[$idx]}" -eq 0 ]]; then
        ready=1
        for dep in ${GRAPH_DEPS[$idx]}; do
          if [[ "${GRAPH_WAVE[$dep]}" -eq 0 ]]; then
            ready=0
            break
          fi
        done
        if [[ "$ready" -eq 1 ]]; then
          batch="$batch $idx"
        fi
      fi
      idx=$((idx + 1))
    done

    [[ -n "$batch" ]] || break
    for idx in $batch; do
      GRAPH_WAVE[$idx]=$wave
    done
  done

  idx=0
  while [[ $idx -lt $TOTAL_RUNS ]]; do
    if [[ "${GRAPH_WAVE[$idx]}" -eq 0 ]]; then
      cyclic="$cyclic ${INCOMPLETE_RUNS[$idx]}"
    fi
    idx=$((idx + 1))
  done

  if [[ -n "$cyclic" ]]; then
    echo "Error: dependsOnRuns cycle - these runs can never become ready:" >&2
    for cid in $cyclic; do
      echo "  - $cid" >&2
    done
    echo "Break the cycle in those runs' prd.json. No runs were started." >&2
    return 1
  fi
  return 0
}

graph_show() {
  local idx=0 dep line
  echo ""
  echo "Resolved dependency graph:"
  while [[ $idx -lt $TOTAL_RUNS ]]; do
    line=""
    for dep in ${GRAPH_DEPS[$idx]}; do
      if [[ -z "$line" ]]; then
        line="${INCOMPLETE_RUNS[$dep]}"
      else
        line="$line, ${INCOMPLETE_RUNS[$dep]}"
      fi
    done
    if [[ -z "$line" ]]; then
      printf "  %s  (waits for nothing)\n" "${INCOMPLETE_RUNS[$idx]}"
    else
      printf "  %s  <- %s\n" "${INCOMPLETE_RUNS[$idx]}" "$line"
    fi
    if [[ -n "${GRAPH_MET_DEPS[$idx]}" ]]; then
      printf "      already merged back:%s\n" "${GRAPH_MET_DEPS[$idx]}"
    fi
    idx=$((idx + 1))
  done
}

graph_show_waves() {
  local idx max=0 wave=1 line
  idx=0
  while [[ $idx -lt $TOTAL_RUNS ]]; do
    if [[ "${GRAPH_WAVE[$idx]}" -gt "$max" ]]; then
      max="${GRAPH_WAVE[$idx]}"
    fi
    idx=$((idx + 1))
  done

  echo ""
  echo "Wave preview (execution is event-driven: a run starts the moment its own"
  echo "dependencies succeed, so these waves are only a preview):"
  while [[ $wave -le $max ]]; do
    line=""
    idx=0
    while [[ $idx -lt $TOTAL_RUNS ]]; do
      if [[ "${GRAPH_WAVE[$idx]}" -eq "$wave" ]]; then
        if [[ -z "$line" ]]; then
          line="${INCOMPLETE_RUNS[$idx]}"
        else
          line="$line  ‖  ${INCOMPLETE_RUNS[$idx]}"
        fi
      fi
      idx=$((idx + 1))
    done
    printf "  Wave %d:  %s\n" "$wave" "$line"
    wave=$((wave + 1))
  done
}

graph_refresh_orch_pids() {
  local idx=0
  ORCH_PIDS=()
  while [[ $idx -lt $TOTAL_RUNS ]]; do
    if [[ "${GRAPH_STATE[$idx]}" == "running" ]]; then
      ORCH_PIDS+=("${GRAPH_PID[$idx]}")
    fi
    idx=$((idx + 1))
  done
}

graph_launch() {
  local idx="$1"
  local run_id="${INCOMPLETE_RUNS[$idx]}"
  local log_file="$RUNS_ROOT/$run_id/orchestrator-$TIMESTAMP.log"

  mkdir -p "$(dirname "$log_file")"
  echo "  -> $run_id  (log: $log_file)"

  # Graph mode never streams a run to the terminal, not even a lone first one:
  # any other run may start alongside it at any moment, and interleaved live
  # output from several runs is unreadable.
  "$RALPH_SCRIPT" --run "$run_id" --tool "$TOOL" >"$log_file" 2>&1 &
  GRAPH_PID[$idx]=$!
  GRAPH_LOG[$idx]="$log_file"
  GRAPH_STATE[$idx]="running"
  # Register the pid before the caller loops again, so a signal arriving mid-loop
  # still finds this child in ORCH_PIDS.
  ORCH_PIDS+=("${GRAPH_PID[$idx]}")
}

# Launch every pending run whose graph dependencies have all succeeded.
graph_launch_ready() {
  local idx=0 dep ready
  while [[ $idx -lt $TOTAL_RUNS ]]; do
    if [[ "${GRAPH_STATE[$idx]}" == "pending" ]]; then
      ready=1
      for dep in ${GRAPH_DEPS[$idx]}; do
        if [[ "${GRAPH_STATE[$dep]}" != "succeeded" ]]; then
          ready=0
          break
        fi
      done
      if [[ "$ready" -eq 1 ]]; then
        graph_launch "$idx"
      fi
    fi
    idx=$((idx + 1))
  done
}

# A failed run takes its whole downstream with it. Sweep until nothing changes so
# indirect dependents are caught too, and carry the original failure's id down
# the chain instead of naming the intermediate run that was itself only blocked.
graph_propagate_blocks() {
  local changed=1 idx dep
  while [[ "$changed" -eq 1 ]]; do
    changed=0
    idx=0
    while [[ $idx -lt $TOTAL_RUNS ]]; do
      if [[ "${GRAPH_STATE[$idx]}" == "pending" ]]; then
        for dep in ${GRAPH_DEPS[$idx]}; do
          case "${GRAPH_STATE[$dep]}" in
            failed|stopped)
              GRAPH_BLOCKER[$idx]="${INCOMPLETE_RUNS[$dep]}"
              ;;
            blocked)
              GRAPH_BLOCKER[$idx]="${GRAPH_BLOCKER[$dep]}"
              ;;
            *)
              # `continue` here belongs to the `for dep` loop; `case` is not one.
              continue
              ;;
          esac
          GRAPH_STATE[$idx]="blocked"
          echo "  [graph] ${INCOMPLETE_RUNS[$idx]}: BLOCKED (${GRAPH_BLOCKER[$idx]} failed)" >&2
          changed=1
          break
        done
      fi
      idx=$((idx + 1))
    done
  done
}

# Returns 0 when every run succeeded, RALPH_RATE_LIMIT_EXIT_CODE on a rate limit,
# 1 when anything failed or was blocked.
graph_execute() {
  local idx rc reaped running rate_limited=0

  echo ""
  echo "==============================================================="
  echo "  Graph execution: $TOTAL_RUNS run(s)"
  echo "==============================================================="

  while true; do
    graph_launch_ready
    graph_refresh_orch_pids

    running=0
    idx=0
    while [[ $idx -lt $TOTAL_RUNS ]]; do
      if [[ "${GRAPH_STATE[$idx]}" == "running" ]]; then
        running=1
      fi
      idx=$((idx + 1))
    done
    [[ "$running" -eq 1 ]] || break

    # Reap in completion order rather than launch order: blocking on one pid
    # would hold back every run that another, already-finished child has just
    # made ready.
    reaped=0
    idx=0
    while [[ $idx -lt $TOTAL_RUNS ]]; do
      if [[ "${GRAPH_STATE[$idx]}" == "running" ]] \
        && ! kill -0 "${GRAPH_PID[$idx]}" 2>/dev/null; then
        reaped=1
        # Capture the child's status directly - see execute_stage for why an
        # `if wait ...; then` would report a failed run as successful.
        rc=0
        wait "${GRAPH_PID[$idx]}" || rc=$?
        GRAPH_RC[$idx]="$rc"
        if [[ "$rc" -eq 0 ]]; then
          GRAPH_STATE[$idx]="succeeded"
          echo "  [graph] ${INCOMPLETE_RUNS[$idx]}: ok"
        elif [[ "$rc" -eq "$RALPH_RATE_LIMIT_EXIT_CODE" ]]; then
          GRAPH_STATE[$idx]="failed"
          rate_limited=1
          echo "  [graph] ${INCOMPLETE_RUNS[$idx]}: rate-limited (exit $rc, see ${GRAPH_LOG[$idx]})" >&2
        else
          GRAPH_STATE[$idx]="failed"
          echo "  [graph] ${INCOMPLETE_RUNS[$idx]}: FAILED (exit $rc, see ${GRAPH_LOG[$idx]})" >&2
        fi
      fi
      idx=$((idx + 1))
    done

    # A rate limit is the one failure that cuts everything short: the remaining
    # runs would only burn requests against the same exhausted quota.
    if [[ "$rate_limited" -eq 1 ]]; then
      graph_refresh_orch_pids
      terminate_orchestrated_runs
      ORCH_PIDS=()
      idx=0
      while [[ $idx -lt $TOTAL_RUNS ]]; do
        if [[ "${GRAPH_STATE[$idx]}" == "running" ]]; then
          GRAPH_STATE[$idx]="stopped"
        fi
        idx=$((idx + 1))
      done
      graph_propagate_blocks
      return "$RALPH_RATE_LIMIT_EXIT_CODE"
    fi

    graph_propagate_blocks

    if [[ "$reaped" -eq 0 ]]; then
      sleep 1
    fi
  done

  ORCH_PIDS=()
  idx=0
  while [[ $idx -lt $TOTAL_RUNS ]]; do
    if [[ "${GRAPH_STATE[$idx]}" != "succeeded" ]]; then
      return 1
    fi
    idx=$((idx + 1))
  done
  return 0
}

graph_summary() {
  local idx any

  echo ""
  echo "==============================================================="
  echo "  Graph summary"
  echo "==============================================================="

  echo "Succeeded:"
  any=0
  idx=0
  while [[ $idx -lt $TOTAL_RUNS ]]; do
    if [[ "${GRAPH_STATE[$idx]}" == "succeeded" ]]; then
      echo "  - ${INCOMPLETE_RUNS[$idx]}"
      any=1
    fi
    idx=$((idx + 1))
  done
  [[ "$any" -eq 1 ]] || echo "  (none)"

  echo "Failed:"
  any=0
  idx=0
  while [[ $idx -lt $TOTAL_RUNS ]]; do
    case "${GRAPH_STATE[$idx]}" in
      failed)
        echo "  - ${INCOMPLETE_RUNS[$idx]} (exit ${GRAPH_RC[$idx]}, log: ${GRAPH_LOG[$idx]})"
        any=1
        ;;
      stopped)
        echo "  - ${INCOMPLETE_RUNS[$idx]} (stopped after a rate limit, log: ${GRAPH_LOG[$idx]})"
        any=1
        ;;
    esac
    idx=$((idx + 1))
  done
  [[ "$any" -eq 1 ]] || echo "  (none)"

  echo "Blocked:"
  any=0
  idx=0
  while [[ $idx -lt $TOTAL_RUNS ]]; do
    case "${GRAPH_STATE[$idx]}" in
      blocked)
        echo "  - ${INCOMPLETE_RUNS[$idx]} (blocked by failed run '${GRAPH_BLOCKER[$idx]}')"
        any=1
        ;;
      pending)
        # Only reachable when the orchestrator stopped before this run's turn.
        echo "  - ${INCOMPLETE_RUNS[$idx]} (never started: orchestrator stopped early)"
        any=1
        ;;
    esac
    idx=$((idx + 1))
  done
  [[ "$any" -eq 1 ]] || echo "  (none)"
}

graph_main() {
  local rc=0

  graph_build || exit 1
  graph_assign_waves || exit 1

  graph_show

  if [[ "$DRY_RUN" == "true" ]]; then
    graph_show_waves
    echo ""
    echo "Dry run: not executing any Ralph runs."
    exit 0
  fi

  if [[ -t 0 ]]; then
    echo ""
    read -r -p "Confirm? [y/N] " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
      echo "Aborted."
      exit 1
    fi
  else
    echo ""
    echo "Graph resolved non-interactively; proceeding without confirmation."
  fi

  # Disable strict mode for the scheduler so a failed run is handled here rather
  # than aborting the orchestrator mid-graph.
  set +e

  START_TIME=$(date +%s)
  graph_execute
  rc=$?
  END_TIME=$(date +%s)

  graph_summary
  echo ""
  echo "Total elapsed: $((END_TIME - START_TIME))s"

  if [[ "$rc" -eq "$RALPH_RATE_LIMIT_EXIT_CODE" ]]; then
    echo "A run detected a 429/rate-limit response. Stopping orchestrator (queued runs skipped)." >&2
    exit "$RALPH_RATE_LIMIT_EXIT_CODE"
  fi
  if [[ "$rc" -ne 0 ]]; then
    echo "Some runs failed or were blocked." >&2
    exit 1
  fi
  echo "All $TOTAL_RUNS run(s) completed successfully."
  exit 0
}

if [[ "$MODE" == "graph" ]]; then
  graph_main
fi

# --- Read plan ----------------------------------------------------------------

if [[ -z "$PLAN_INPUT" ]]; then
  if [[ ! -t 0 ]]; then
    echo "Error: No plan provided and stdin is not interactive." >&2
    echo "Pass --plan \"1 > 2,3 > 4\" or run from a terminal." >&2
    exit 1
  fi
  echo "Plan syntax: ',' = parallel, '>' = serial. Example: 1 > 2,3 > 4"
  read -r -p "Plan> " PLAN_INPUT
fi

# --- Parse plan ---------------------------------------------------------------

PLAN_STRIPPED="${PLAN_INPUT//[[:space:]]/}"

if [[ -z "$PLAN_STRIPPED" ]]; then
  echo "Error: Empty plan." >&2
  exit 1
fi

if [[ ! "$PLAN_STRIPPED" =~ ^[0-9,\>]+$ ]]; then
  echo "Error: Plan contains invalid characters. Allowed: digits, ',', '>'." >&2
  exit 1
fi

# Reject leading/trailing/adjacent separators up front (read drops trailing
# empty fields silently otherwise).
case "$PLAN_STRIPPED" in
  ,*|*,|\>*|*\>)
    echo "Error: Plan must not start or end with ',' or '>'." >&2
    exit 1
    ;;
esac
if [[ "$PLAN_STRIPPED" == *,,* || "$PLAN_STRIPPED" == *\>\>* \
   || "$PLAN_STRIPPED" == *,\>* || "$PLAN_STRIPPED" == *\>,* ]]; then
  echo "Error: Plan has adjacent separators (',,' / '>>' / ',>' / '>,')." >&2
  exit 1
fi

PLAN_STAGES=()
SEEN_TOKENS=":"

OLD_IFS="$IFS"
IFS='>' read -ra RAW_STAGES <<< "$PLAN_STRIPPED"
IFS="$OLD_IFS"

for raw in "${RAW_STAGES[@]}"; do
  if [[ -z "$raw" ]]; then
    echo "Error: Empty stage in plan (check for consecutive '>' or stray '>')." >&2
    exit 1
  fi

  IFS=',' read -ra RAW_TOKENS <<< "$raw"
  IFS="$OLD_IFS"

  stage_runs=""
  for tok in "${RAW_TOKENS[@]}"; do
    if [[ -z "$tok" ]]; then
      echo "Error: Empty token in plan (check for consecutive ',' or stray ',')." >&2
      exit 1
    fi
    if [[ ! "$tok" =~ ^[0-9]+$ ]]; then
      echo "Error: Non-numeric token '$tok' in plan." >&2
      exit 1
    fi

    idx=$((tok - 1))
    if [[ $idx -lt 0 || $idx -ge $TOTAL_RUNS ]]; then
      echo "Error: Number $tok is out of range (1-$TOTAL_RUNS)." >&2
      exit 1
    fi

    case "$SEEN_TOKENS" in
      *":$tok:"*)
        echo "Error: Run number $tok appears more than once in plan." >&2
        exit 1
        ;;
    esac
    SEEN_TOKENS="$SEEN_TOKENS$tok:"

    if [[ -z "$stage_runs" ]]; then
      stage_runs="${INCOMPLETE_RUNS[$idx]}"
    else
      stage_runs="$stage_runs ${INCOMPLETE_RUNS[$idx]}"
    fi
  done

  PLAN_STAGES+=("$stage_runs")
done

# --- Show resolved plan -------------------------------------------------------

echo ""
echo "Resolved plan:"
i=0
while [[ $i -lt ${#PLAN_STAGES[@]} ]]; do
  read -ra stage_runs <<< "${PLAN_STAGES[$i]}"
  if [[ ${#stage_runs[@]} -eq 1 ]]; then
    printf "  Stage %d:  %s\n" "$((i + 1))" "${stage_runs[0]}"
  else
    line=""
    j=0
    while [[ $j -lt ${#stage_runs[@]} ]]; do
      if [[ -z "$line" ]]; then
        line="${stage_runs[$j]}"
      else
        line="$line  ‖  ${stage_runs[$j]}"
      fi
      j=$((j + 1))
    done
    printf "  Stage %d:  %s\n" "$((i + 1))" "$line"
  fi
  i=$((i + 1))
done

# Unscheduled runs (will not be touched).
UNSCHEDULED=()
i=0
while [[ $i -lt $TOTAL_RUNS ]]; do
  num=$((i + 1))
  case "$SEEN_TOKENS" in
    *":$num:"*) ;;
    *) UNSCHEDULED+=("${INCOMPLETE_RUNS[$i]}") ;;
  esac
  i=$((i + 1))
done

if [[ ${#UNSCHEDULED[@]} -gt 0 ]]; then
  echo ""
  echo "Unscheduled (will be skipped):"
  for r in "${UNSCHEDULED[@]}"; do
    echo "  - $r"
  done
fi

# --- Confirm ------------------------------------------------------------------

if [[ "$DRY_RUN" == "true" ]]; then
  echo ""
  echo "Dry run: not executing any Ralph runs."
  exit 0
fi

if [[ -t 0 ]]; then
  echo ""
  read -r -p "Confirm? [y/N] " CONFIRM
  if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 1
  fi
else
  echo ""
  echo "Plan supplied non-interactively; proceeding without confirmation."
fi

# --- Execution (stage mode) ---------------------------------------------------

execute_stage() {
  local stage_num="$1"
  shift
  local runs=("$@")

  echo ""
  echo "==============================================================="
  if [[ ${#runs[@]} -eq 1 ]]; then
    echo "  Stage $stage_num: ${runs[0]}"
  else
    echo "  Stage $stage_num: parallel (${#runs[@]} runs)"
    for r in "${runs[@]}"; do
      echo "    - $r"
    done
  fi
  echo "==============================================================="

  if [[ ${#runs[@]} -eq 1 ]]; then
    local args=(--run "${runs[0]}" --tool "$TOOL")
    "$RALPH_SCRIPT" "${args[@]}" &
    ORCH_PIDS=("$!")
    # Capture the child's status directly. `if wait ...; then ...; fi` cannot be
    # used here: an `if` whose condition fails and that has no `else` branch
    # exits 0, so reading $? after `fi` reports success for a failed run and the
    # orchestrator walks on to the next stage.
    local rc=0
    wait "${ORCH_PIDS[0]}" || rc=$?
    ORCH_PIDS=()
    if [[ "$rc" -eq 0 ]]; then
      echo "[stage $stage_num] ${runs[0]}: ok"
      return 0
    fi
    if [[ "$rc" -eq "$RALPH_RATE_LIMIT_EXIT_CODE" ]]; then
      echo "[stage $stage_num] ${runs[0]}: rate-limited (exit $rc)" >&2
      return "$RALPH_RATE_LIMIT_EXIT_CODE"
    fi
    echo "[stage $stage_num] ${runs[0]}: FAILED (exit $rc)" >&2
    return "$rc"
  fi

  # Parallel: redirect each run to its own log file.
  local pids=() logs=() names=()
  local run_id log_file
  for run_id in "${runs[@]}"; do
    log_file="$RUNS_ROOT/$run_id/orchestrator-$TIMESTAMP.log"
    mkdir -p "$(dirname "$log_file")"
    echo "  -> $run_id  (log: $log_file)"

    local args=(--run "$run_id" --tool "$TOOL")

    "$RALPH_SCRIPT" "${args[@]}" >"$log_file" 2>&1 &
    pids+=($!)
    logs+=("$log_file")
    names+=("$run_id")
  done

  ORCH_PIDS=("${pids[@]}")

  local stage_failed=0 stage_rate_limited=0 rc reaped
  local pending=() still=()
  local k=0
  while [[ $k -lt ${#pids[@]} ]]; do
    pending+=("$k")
    k=$((k + 1))
  done

  # Reap in completion order rather than launch order. Waiting on pids[0] first
  # would hide a later sibling's failure until every earlier run has finished,
  # so the failure is recorded the moment the run exits (after its own unblock
  # round). Siblings still run to completion; only the next stage is withheld.
  while [[ ${#pending[@]} -gt 0 ]]; do
    still=()
    reaped=0
    for k in "${pending[@]}"; do
      if kill -0 "${pids[$k]}" 2>/dev/null; then
        still+=("$k")
        continue
      fi
      reaped=1
      rc=0
      wait "${pids[$k]}" || rc=$?
      if [[ "$rc" -eq 0 ]]; then
        echo "  [stage $stage_num] ${names[$k]}: ok"
      elif [[ "$rc" -eq "$RALPH_RATE_LIMIT_EXIT_CODE" ]]; then
        echo "  [stage $stage_num] ${names[$k]}: rate-limited (exit $rc, see ${logs[$k]})" >&2
        stage_rate_limited=1
        stage_failed=1
      else
        echo "  [stage $stage_num] ${names[$k]}: FAILED (exit $rc, see ${logs[$k]})" >&2
        stage_failed=1
      fi
    done

    # A rate limit is the one failure that cuts the stage short: the remaining
    # runs would only burn requests against the same exhausted quota.
    if [[ "$stage_rate_limited" -eq 1 ]]; then
      terminate_orchestrated_runs
      break
    fi

    pending=("${still[@]}")
    if [[ ${#pending[@]} -gt 0 && "$reaped" -eq 0 ]]; then
      sleep 1
    fi
  done

  ORCH_PIDS=()
  if [[ "$stage_rate_limited" -eq 1 ]]; then
    return "$RALPH_RATE_LIMIT_EXIT_CODE"
  fi
  return "$stage_failed"
}

# Disable strict mode for the loop so we can react to per-stage failures.
set +e

START_TIME=$(date +%s)
i=0
while [[ $i -lt ${#PLAN_STAGES[@]} ]]; do
  read -ra STAGE_RUNS <<< "${PLAN_STAGES[$i]}"
  execute_stage "$((i + 1))" "${STAGE_RUNS[@]}"
  rc=$?
  if [[ $rc -ne 0 ]]; then
    END_TIME=$(date +%s)
    echo ""
    if [[ "$rc" -eq "$RALPH_RATE_LIMIT_EXIT_CODE" ]]; then
      echo "Stage $((i + 1)) detected a 429/rate-limit response. Stopping orchestrator (later stages skipped)." >&2
      echo "Total elapsed: $((END_TIME - START_TIME))s"
      exit "$RALPH_RATE_LIMIT_EXIT_CODE"
    fi
    echo "Stage $((i + 1)) had failures. Stopping orchestrator (later stages skipped)." >&2
    echo "Total elapsed: $((END_TIME - START_TIME))s"
    exit "$rc"
  fi
  i=$((i + 1))
done

END_TIME=$(date +%s)
echo ""
echo "All ${#PLAN_STAGES[@]} stage(s) completed successfully."
echo "Total elapsed: $((END_TIME - START_TIME))s"
exit 0
