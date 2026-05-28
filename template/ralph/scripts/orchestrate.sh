#!/bin/bash
# Ralph Orchestrator - Run multiple Ralph runs in stages.
#
# Usage:
#   ./orchestrate.sh [--tool claude|codex] [--plan "1 > 2,3 > 4"]
#                    [--dry-run] [max_iterations]
#
# Plan syntax:
#   ','  parallel within the same stage
#   '>'  sequential across stages
#   Whitespace is ignored. Example: "1 > 2,3 > 4" runs run #1 first, then #2
#   and #3 in parallel, then #4.
#
# Behavior:
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
# Environment:
#   RALPH_PLAN     Default plan string (overridden by --plan).
#   RALPH_NOTIFY=0 Disable Ralph's per-run desktop notifications.

set -e

TOOL="${RALPH_TOOL:-codex}"
MAX_ITERATIONS=""
PLAN_INPUT="${RALPH_PLAN:-}"
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
      shift 2
      ;;
    --plan=*)
      PLAN_INPUT="${1#*=}"
      shift
      ;;
    --dry-run)
      DRY_RUN="true"
      shift
      ;;
    -h|--help)
      sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      if [[ "$1" =~ ^[0-9]+$ ]]; then
        MAX_ITERATIONS="$1"
      else
        echo "Error: Unknown argument '$1'" >&2
        exit 1
      fi
      shift
      ;;
  esac
done

if [[ "$TOOL" != "claude" && "$TOOL" != "codex" ]]; then
  echo "Error: Invalid tool '$TOOL'. Must be 'claude' or 'codex'." >&2
  exit 1
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

# --- Run discovery (mirrors ralph.sh) -----------------------------------------

run_prd_all_passed() {
  local prd_file="$1"
  jq -e '
    (.userStories | length) > 0
    and (.userStories | all(.passes == true))
  ' "$prd_file" >/dev/null 2>&1
}

run_merge_back_complete() {
  local run_dir="$1"
  local prd_file="$run_dir/prd.json"
  local state_file="$run_dir/state.json"
  local marker_file="$run_dir/.merge-back-done"
  local target_branch base_branch

  target_branch=$(jq -r '.branchName // empty' "$prd_file" 2>/dev/null || echo "")
  base_branch=$(jq -r '.baseBranch // empty' "$state_file" 2>/dev/null || echo "")

  if [[ -z "$target_branch" || -z "$base_branch" || "$target_branch" == "$base_branch" ]]; then
    return 0
  fi

  if [[ -f "$marker_file" ]] \
    && grep -qx "status=done" "$marker_file" \
    && grep -qx "base_branch=$base_branch" "$marker_file" \
    && grep -qx "target_branch=$target_branch" "$marker_file"; then
    return 0
  fi

  if git -C "$REPO_ROOT" rev-parse --verify "$base_branch" >/dev/null 2>&1 \
    && git -C "$REPO_ROOT" rev-parse --verify "$target_branch" >/dev/null 2>&1 \
    && git -C "$REPO_ROOT" merge-base --is-ancestor "$target_branch" "$base_branch"; then
    return 0
  fi

  return 1
}

run_is_complete() {
  local run_dir="$1"
  run_prd_all_passed "$run_dir/prd.json" && run_merge_back_complete "$run_dir"
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

# --- Execution ----------------------------------------------------------------

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
    [[ -n "$MAX_ITERATIONS" ]] && args+=("$MAX_ITERATIONS")
    "$RALPH_SCRIPT" "${args[@]}" &
    ORCH_PIDS=("$!")
    if wait "${ORCH_PIDS[0]}"; then
      ORCH_PIDS=()
      echo "[stage $stage_num] ${runs[0]}: ok"
      return 0
    fi
    local rc=$?
    ORCH_PIDS=()
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
    [[ -n "$MAX_ITERATIONS" ]] && args+=("$MAX_ITERATIONS")

    "$RALPH_SCRIPT" "${args[@]}" >"$log_file" 2>&1 &
    pids+=($!)
    logs+=("$log_file")
    names+=("$run_id")
  done

  ORCH_PIDS=("${pids[@]}")

  local stage_failed=0 stage_rate_limited=0 rc
  local k=0
  while [[ $k -lt ${#pids[@]} ]]; do
    if wait "${pids[$k]}"; then
      echo "  [stage $stage_num] ${names[$k]}: ok"
    else
      rc=$?
      if [[ "$rc" -eq "$RALPH_RATE_LIMIT_EXIT_CODE" ]]; then
        echo "  [stage $stage_num] ${names[$k]}: rate-limited (exit $rc, see ${logs[$k]})" >&2
        stage_rate_limited=1
        stage_failed=1
        terminate_orchestrated_runs
        break
      fi
      echo "  [stage $stage_num] ${names[$k]}: FAILED (exit $rc, see ${logs[$k]})" >&2
      stage_failed=1
    fi
    k=$((k + 1))
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
