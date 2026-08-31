#!/bin/bash
# Ralph Orchestrator - Run multiple Ralph runs in stages or as a dependency graph.
#
# Usage:
#   ./orchestrate.sh [--tool claude|codex|pi] [--only "1,3-5"]
#                    [--plan "1 > 2,3 > 4" | --graph] [--dry-run]
#
# Selection:
#   Nothing is scheduled that you did not pick. --only (or RALPH_ONLY) narrows
#   the incomplete runs to a subset - numbers from the printed list, run ids,
#   '2-4' ranges, ',' or space separated - and graph mode asks for the same
#   thing interactively when --only was not given. A stage plan is its own
#   selection: the runs it does not name are skipped, as before.
#   The order is then derived inside that subset only. A run whose
#   `dependsOnRuns` names something left out of the selection cannot honestly
#   run - its worktree would not contain that work - so graph mode reports it
#   as unrunnable, by name and with the reason, and runs everything else.
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
#   - Nodes are the selected runs; edges come from each run's `dependsOnRuns`.
#     A dependency that already finished and merged back (or was archived) is
#     dropped. A dependency on a real run that this invocation did not select
#     takes the dependent (and its own downstream) out of the schedule, listed
#     with the reason. A dependency naming no known run at all is a hard error,
#     as is a cycle.
#   - Scheduling is event-driven, not wave-locked: every run whose graph
#     dependencies have succeeded starts immediately, so a run never waits on
#     an unrelated sibling. Every run logs to its own file.
#   - A failed run blocks its transitive downstream; unrelated runs keep going.
#   - A 429/rate-limit response stops the in-flight runs and the orchestrator.
#   - --dry-run prints the edges and a topological wave preview, then exits.
#
# Terminal:
#   Parallel runs go to log files, so nothing they print reaches this terminal.
#   Each run writes its live state to ralph/status/<run_id>.json instead, and a
#   status board is pinned to the bottom of this terminal - one row per run,
#   with the phase, current story, round and clock. It only ever writes to
#   /dev/tty, so redirected output stays plain text.
#
# Environment:
#   RALPH_PLAN     Default plan string (overridden by --plan, ignored by --graph).
#   RALPH_ONLY     Default selection string (overridden by --only).
#   RALPH_NOTIFY=0 Disable Ralph's per-run desktop notifications.
#   RALPH_BOARD=0  Disable the status board.

set -e

TOOL="${RALPH_TOOL:-codex}"
PLAN_INPUT="${RALPH_PLAN:-}"
ONLY_INPUT="${RALPH_ONLY:-}"
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
    --only)
      ONLY_INPUT="$2"
      shift 2
      ;;
    --only=*)
      ONLY_INPUT="${1#*=}"
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
      sed -n '2,70p' "$0" | sed 's/^# \{0,1\}//'
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

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/run-context.sh"
# shellcheck source=lib/tool-registry.sh
. "$LIB_DIR/tool-registry.sh"

ralph_tool_validate "$TOOL" >&2 || exit 1

if [[ "$GRAPH_FLAG" == "true" && "$PLAN_FROM_FLAG" == "true" ]]; then
  echo "Error: --plan and --graph are mutually exclusive." >&2
  exit 1
fi

# An inherited RALPH_PLAN is only a default; an explicit --graph outranks it.
if [[ "$GRAPH_FLAG" == "true" ]]; then
  PLAN_INPUT=""
fi

RALPH_SCRIPT="$SCRIPT_DIR/ralph.sh"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"

if [[ ! -x "$RALPH_SCRIPT" ]]; then
  echo "Error: Cannot execute $RALPH_SCRIPT" >&2
  exit 1
fi

# Canonical run discovery and dependency-completion rules.
# shellcheck source=lib/runs.sh
. "$SCRIPT_DIR/lib/runs.sh"
# Terminal presentation shared with ralph.sh.
# shellcheck source=lib/log.sh
. "$SCRIPT_DIR/lib/log.sh"
# shellcheck source=lib/status-board.sh
. "$SCRIPT_DIR/lib/status-board.sh"
# Child-process lifecycle shared by both scheduling modes.
# shellcheck source=lib/orchestrator-executor.sh
. "$SCRIPT_DIR/lib/orchestrator-executor.sh"
# Which runs this invocation may start, and how an edge out of that set reads.
# shellcheck source=lib/orchestrator-selection.sh
. "$SCRIPT_DIR/lib/orchestrator-selection.sh"
# Mode-specific planning and scheduling.
# shellcheck source=lib/orchestrator-graph.sh
. "$SCRIPT_DIR/lib/orchestrator-graph.sh"
# shellcheck source=lib/orchestrator-stage.sh
. "$SCRIPT_DIR/lib/orchestrator-stage.sh"

INCOMPLETE_RUNS=()
while IFS= read -r run_id; do
  INCOMPLETE_RUNS+=("$run_id")
done < <(discover_run_ids)

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

# An explicit selection narrows the list before the mode is chosen, so a plan's
# numbers keep addressing exactly what was printed last.
selection_apply_spec "$ONLY_INPUT" || exit 1

MODE="stage"
if [[ -n "$PLAN_INPUT" ]]; then
  MODE="stage"
elif [[ "$GRAPH_FLAG" == "true" ]]; then
  MODE="graph"
elif graph_edges_declared; then
  MODE="graph"
  echo "Found dependsOnRuns edges: scheduling as a dependency graph (no --plan given)."
fi

# A stage plan already says which runs to touch; graph mode has no such input,
# so it asks rather than assuming the whole backlog.
if [[ "$MODE" == "graph" && -z "$ONLY_INPUT" ]]; then
  selection_prompt || exit 1
fi

cleanup_on_signal() {
  ralph_board_stop || true
  orchestrator_executor_terminate
  exit 130
}
trap cleanup_on_signal INT TERM
trap 'ralph_board_resize || true' WINCH

case "$MODE" in
  graph) graph_main ;;
  stage) stage_main ;;
esac
