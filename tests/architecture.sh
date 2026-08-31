#!/bin/bash
# Cheap structural constraints for the boundaries this repository depends on.
# Behavior tests prove the flows; this gate prevents the thin entrypoints and
# single-owner rules from quietly collapsing back into monoliths.

set -eu

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPTS_DIR="$REPO_ROOT/template/ralph/scripts"

fail() {
  echo "architecture check failed: $1" >&2
  exit 1
}

assert_max_lines() {
  local file="$1"
  local maximum="$2"
  local actual

  actual=$(wc -l < "$file" | tr -d ' ')
  if [[ "$actual" -gt "$maximum" ]]; then
    fail "${file#$REPO_ROOT/} has $actual lines; thin-entrypoint limit is $maximum"
  fi
}

assert_contains() {
  local file="$1"
  local text="$2"
  grep -Fq "$text" "$file" || fail "${file#$REPO_ROOT/} does not use $text"
}

assert_absent() {
  local file="$1"
  local text="$2"
  if grep -Fq "$text" "$file"; then
    fail "${file#$REPO_ROOT/} still contains retired owner $text"
  fi
}

assert_max_lines "$REPO_ROOT/bin/ralph-kit.mjs" 100
assert_max_lines "$SCRIPTS_DIR/ralph.sh" 240
assert_max_lines "$SCRIPTS_DIR/orchestrate.sh" 240

for module in run-bootstrap wrap-up-phases story-phase phase-controller; do
  assert_contains "$SCRIPTS_DIR/ralph.sh" "source \"\$LIB_DIR/$module.sh\""
done
assert_contains "$SCRIPTS_DIR/ralph.sh" 'ralph_phase_loop'
assert_contains "$SCRIPTS_DIR/ralph.sh" 'ralph_tool_validate "$TOOL"'
assert_contains "$SCRIPTS_DIR/lint-prd.sh" 'lib/run-context.sh'
assert_absent "$SCRIPTS_DIR/lint-prd.sh" 'RUN_ID" =~'
for context_consumer in orchestrate.sh archive-runs.sh migrate-progress-json.sh; do
  assert_contains "$SCRIPTS_DIR/$context_consumer" 'lib/run-context.sh'
done
assert_absent "$SCRIPTS_DIR/orchestrate.sh" 'RUNS_ROOT="$RALPH_ROOT/runs"'
assert_absent "$SCRIPTS_DIR/archive-runs.sh" 'RUNS_ROOT="$RALPH_ROOT/runs"'

for module in orchestrator-selection orchestrator-executor orchestrator-graph orchestrator-stage; do
  assert_contains "$SCRIPTS_DIR/orchestrate.sh" ". \"\$SCRIPT_DIR/lib/$module.sh\""
done
assert_contains "$SCRIPTS_DIR/orchestrate.sh" 'ralph_tool_validate "$TOOL"'

# Both schedulers read dependsOnRuns through the selection module, so "an edge
# out of this invocation's scope" means the same thing in either mode.
for scheduler in orchestrator-graph orchestrator-stage; do
  assert_contains "$SCRIPTS_DIR/lib/$scheduler.sh" 'selection_run_deps'
  assert_absent "$SCRIPTS_DIR/lib/$scheduler.sh" '.dependsOnRuns // []'
done

# Persistence is independently reusable; only run-observers may couple it to
# the optional terminal projection.
assert_absent "$SCRIPTS_DIR/lib/run-status.sh" 'ralph_progress_'

# Stage and graph schedulers share the executor's state model and PID registry.
for retired in GRAPH_STATE GRAPH_PID GRAPH_LOG GRAPH_RC STAGE_NAMES STAGE_STATES \
  STAGE_RCS terminate_orchestrated_runs clear_stale_status_files; do
  assert_absent "$SCRIPTS_DIR/orchestrate.sh" "$retired"
  assert_absent "$SCRIPTS_DIR/lib/orchestrator-graph.sh" "$retired"
  assert_absent "$SCRIPTS_DIR/lib/orchestrator-stage.sh" "$retired"
done

phase_selector_count=$(grep -h '^ralph_select_phase()' "$SCRIPTS_DIR"/lib/*.sh | wc -l | tr -d ' ')
[[ "$phase_selector_count" -eq 1 ]] \
  || fail "expected one ralph_select_phase owner, found $phase_selector_count"

run_completion_count=$(grep -h '^run_is_complete()' "$SCRIPTS_DIR"/lib/*.sh | wc -l | tr -d ' ')
[[ "$run_completion_count" -eq 1 ]] \
  || fail "expected one run_is_complete owner, found $run_completion_count"

echo "architecture checks passed"
