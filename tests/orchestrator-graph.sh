#!/bin/bash
# The orchestrator can schedule runs straight from their `dependsOnRuns` edges
# instead of a hand-typed stage plan: a run starts as soon as its own
# dependencies succeed, a failure blocks only its downstream, and a broken graph
# (cycle or dangling reference) is refused before anything is launched.

set -e

TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/ralph-orchestrator-graph-test.XXXXXX")
FIXTURE_REPO="$TEST_ROOT/repo"
RALPH_ROOT="$FIXTURE_REPO/ralph"
SCRIPTS_DIR="$RALPH_ROOT/scripts"
ORCHESTRATOR="$SCRIPTS_DIR/orchestrate.sh"

cleanup_test() {
  rm -rf "$TEST_ROOT"
}
trap cleanup_test EXIT

mkdir -p "$FIXTURE_REPO"
cp -R "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/template/ralph" "$RALPH_ROOT"
# The installer marks the shipped scripts executable; mirror that here.
chmod +x "$SCRIPTS_DIR"/*.sh

# Stand in for ralph.sh: record start/end events in order, honour a per-run
# delay, exit with a per-run status, and on success mark the run's PRD complete
# the way a real successful run leaves the base branch (empty branchName keeps
# merge-back trivially complete, so the dir reads as finished in place).
# Behavior file format: "<exit_code> <delay_seconds>".
cat > "$SCRIPTS_DIR/ralph.sh" <<'EOF'
#!/bin/bash

set -e

STUB_SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

run_id=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --run)
      run_id="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

printf 'start %s\n' "$run_id" >> "$FAKE_RALPH_EVENTS_FILE"

exit_code=0
delay=0
if [[ -f "$FAKE_RALPH_BEHAVIOR_DIR/$run_id" ]]; then
  read -r exit_code delay < "$FAKE_RALPH_BEHAVIOR_DIR/$run_id"
fi

if [[ "$delay" -gt 0 ]]; then
  sleep "$delay"
fi

if [[ "$exit_code" -eq 0 ]]; then
  prd_file="$STUB_SCRIPTS_DIR/../runs/$run_id/prd.json"
  jq '.userStories |= map(.passes = true)' "$prd_file" > "$prd_file.tmp"
  mv "$prd_file.tmp" "$prd_file"
fi

printf 'end %s\n' "$run_id" >> "$FAKE_RALPH_EVENTS_FILE"
echo "fake ralph $run_id exiting $exit_code"
exit "$exit_code"
EOF
chmod +x "$SCRIPTS_DIR/ralph.sh"

export FAKE_RALPH_BEHAVIOR_DIR="$TEST_ROOT/behavior"
mkdir -p "$FAKE_RALPH_BEHAVIOR_DIR"

reset_case() {
  export FAKE_RALPH_EVENTS_FILE="$TEST_ROOT/events-$1"
  : > "$FAKE_RALPH_EVENTS_FILE"
  rm -f "$FAKE_RALPH_BEHAVIOR_DIR"/*
  rm -rf "$RALPH_ROOT/runs"
  mkdir -p "$RALPH_ROOT/runs"
}

# make_run <run_id> <passes:true|false> [dep_run_id ...]
make_run() {
  local run_id="$1" passes="$2"
  shift 2
  local deps_json="[]"
  if [[ $# -gt 0 ]]; then
    deps_json=$(printf '%s\n' "$@" | jq -R . | jq -s -c .)
  fi

  mkdir -p "$RALPH_ROOT/runs/$run_id"
  jq -n \
    --arg project "$run_id" \
    --argjson passes "$passes" \
    --argjson deps "$deps_json" \
    '{
      project: $project,
      branchName: "",
      dependsOnRuns: $deps,
      userStories: [
        {
          id: "US-001",
          title: "The only story",
          description: "Drives \($project).",
          acceptanceCriteria: ["Decided by the fake ralph.sh."],
          passes: $passes,
          notes: ""
        }
      ]
    }' > "$RALPH_ROOT/runs/$run_id/prd.json"
}

fail_test() {
  echo "$1" >&2
  echo "--- orchestrator output ---" >&2
  cat "$2" >&2
  echo "--- run events ---" >&2
  cat "$FAKE_RALPH_EVENTS_FILE" >&2
  exit 1
}

# Line number of an event in the ordered event log, or empty when absent.
event_line() {
  grep -n -x "$1" "$FAKE_RALPH_EVENTS_FILE" | head -1 | cut -d: -f1
}

# --- Case 1: a diamond runs A, then B ‖ C, then D -----------------------------
#
# run-done is already complete, so run-a's edge to it is dropped rather than
# treated as an unschedulable reference.

reset_case "diamond"
make_run run-done true
make_run run-a false run-done
make_run run-b false run-a
make_run run-c false run-a
make_run run-d false run-b run-c
echo "0 1" > "$FAKE_RALPH_BEHAVIOR_DIR/run-a"
echo "0 2" > "$FAKE_RALPH_BEHAVIOR_DIR/run-b"
echo "0 2" > "$FAKE_RALPH_BEHAVIOR_DIR/run-c"
echo "0 0" > "$FAKE_RALPH_BEHAVIOR_DIR/run-d"
OUTPUT_FILE="$TEST_ROOT/output-diamond"

set +e
"$ORCHESTRATOR" --tool codex --graph > "$OUTPUT_FILE" 2>&1 < /dev/null
status=$?
set -e

if [[ "$status" -ne 0 ]]; then
  fail_test "Expected the diamond graph to exit 0, got $status" "$OUTPUT_FILE"
fi

if grep -q "run-done" "$FAKE_RALPH_EVENTS_FILE"; then
  fail_test "The already-complete run was scheduled" "$OUTPUT_FILE"
fi

if grep -q "run-a  <- run-done" "$OUTPUT_FILE"; then
  fail_test "A satisfied dependency was kept as a graph edge" "$OUTPUT_FILE"
fi
grep -q "already merged back: run-done" "$OUTPUT_FILE" \
  || fail_test "Expected the satisfied dependency to be reported as merged back" "$OUTPUT_FILE"

start_a=$(event_line "start run-a")
end_a=$(event_line "end run-a")
start_b=$(event_line "start run-b")
end_b=$(event_line "end run-b")
start_c=$(event_line "start run-c")
end_c=$(event_line "end run-c")
start_d=$(event_line "start run-d")
for pair in "start_a:$start_a" "end_a:$end_a" "start_b:$start_b" "end_b:$end_b" \
            "start_c:$start_c" "end_c:$end_c" "start_d:$start_d"; do
  if [[ -z "${pair#*:}" ]]; then
    fail_test "Missing event: ${pair%%:*}" "$OUTPUT_FILE"
  fi
done

if [[ "$start_a" -ne 1 ]]; then
  fail_test "run-a did not start first (event line $start_a)" "$OUTPUT_FILE"
fi
if [[ "$end_a" -ne 2 ]]; then
  fail_test "Another run started while run-a was still going (end run-a at line $end_a)" "$OUTPUT_FILE"
fi
if [[ "$start_b" -lt "$end_a" || "$start_c" -lt "$end_a" ]]; then
  fail_test "A downstream run started before run-a finished" "$OUTPUT_FILE"
fi

# Both start before either ends: they really overlapped rather than serialized.
later_start=$start_b
if [[ "$start_c" -gt "$later_start" ]]; then
  later_start=$start_c
fi
earlier_end=$end_b
if [[ "$end_c" -lt "$earlier_end" ]]; then
  earlier_end=$end_c
fi
if [[ "$later_start" -gt "$earlier_end" ]]; then
  fail_test "run-b and run-c ran one after the other instead of in parallel" "$OUTPUT_FILE"
fi

if [[ "$start_d" -lt "$end_b" || "$start_d" -lt "$end_c" ]]; then
  fail_test "run-d started before both of its dependencies finished" "$OUTPUT_FILE"
fi

grep -q "Graph summary" "$OUTPUT_FILE" \
  || fail_test "Expected a graph summary" "$OUTPUT_FILE"
grep -q "All 4 run(s) completed successfully." "$OUTPUT_FILE" \
  || fail_test "Expected the success line for all four scheduled runs" "$OUTPUT_FILE"

# --- Case 2: a failure blocks its downstream only -----------------------------

reset_case "failure"
make_run run-a false
make_run run-b false run-a
make_run run-c false
echo "1 0" > "$FAKE_RALPH_BEHAVIOR_DIR/run-a"   # fails immediately
echo "0 2" > "$FAKE_RALPH_BEHAVIOR_DIR/run-c"   # unrelated, still running
OUTPUT_FILE="$TEST_ROOT/output-failure"

set +e
"$ORCHESTRATOR" --tool codex --graph > "$OUTPUT_FILE" 2>&1 < /dev/null
status=$?
set -e

if [[ "$status" -eq 0 ]]; then
  fail_test "Expected a non-zero exit after a failed run" "$OUTPUT_FILE"
fi

if grep -q "^start run-b$" "$FAKE_RALPH_EVENTS_FILE"; then
  fail_test "The blocked downstream run was launched anyway" "$OUTPUT_FILE"
fi

grep -qx "end run-c" "$FAKE_RALPH_EVENTS_FILE" \
  || fail_test "The unrelated run was cut short instead of finishing" "$OUTPUT_FILE"

grep -q "run-a: FAILED (exit 1" "$OUTPUT_FILE" \
  || fail_test "Expected the failed run's exit code to be reported" "$OUTPUT_FILE"
grep -q "run-b: BLOCKED (run-a failed)" "$OUTPUT_FILE" \
  || fail_test "Expected run-b to be reported as blocked by run-a" "$OUTPUT_FILE"

# The summary must sort all three runs into the right list.
summary_start=$(grep -n "Graph summary" "$OUTPUT_FILE" | head -1 | cut -d: -f1)
tail -n "+$summary_start" "$OUTPUT_FILE" > "$TEST_ROOT/summary-failure"
awk '/^Succeeded:/{s=1;next} /^Failed:/{s=0} s' "$TEST_ROOT/summary-failure" \
  | grep -q -- "- run-c" \
  || fail_test "Expected run-c under Succeeded" "$OUTPUT_FILE"
awk '/^Failed:/{s=1;next} /^Blocked:/{s=0} s' "$TEST_ROOT/summary-failure" \
  | grep -q -- "- run-a (exit 1, log: " \
  || fail_test "Expected run-a under Failed with its exit code and log path" "$OUTPUT_FILE"
awk '/^Blocked:/{s=1;next} s' "$TEST_ROOT/summary-failure" \
  | grep -q -- "- run-b (blocked by failed run 'run-a')" \
  || fail_test "Expected run-b under Blocked, naming run-a" "$OUTPUT_FILE"

# --- Case 3: a cycle is refused before anything is launched -------------------

reset_case "cycle"
make_run run-x false run-y
make_run run-y false run-x
OUTPUT_FILE="$TEST_ROOT/output-cycle"

set +e
"$ORCHESTRATOR" --tool codex --graph > "$OUTPUT_FILE" 2>&1 < /dev/null
status=$?
set -e

if [[ "$status" -eq 0 ]]; then
  fail_test "Expected a non-zero exit on a dependency cycle" "$OUTPUT_FILE"
fi
if [[ -s "$FAKE_RALPH_EVENTS_FILE" ]]; then
  fail_test "Runs were launched despite the cycle" "$OUTPUT_FILE"
fi
grep -qi "cycle" "$OUTPUT_FILE" \
  || fail_test "Expected the error to name the problem as a cycle" "$OUTPUT_FILE"
grep -q -- "- run-x" "$OUTPUT_FILE" \
  || fail_test "Expected run-x to be listed in the cycle" "$OUTPUT_FILE"
grep -q -- "- run-y" "$OUTPUT_FILE" \
  || fail_test "Expected run-y to be listed in the cycle" "$OUTPUT_FILE"

# --- Case 4: a dangling reference is refused before anything is launched ------

reset_case "ghost"
make_run run-a false ghost
make_run run-b false
OUTPUT_FILE="$TEST_ROOT/output-ghost"

set +e
"$ORCHESTRATOR" --tool codex --graph > "$OUTPUT_FILE" 2>&1 < /dev/null
status=$?
set -e

if [[ "$status" -eq 0 ]]; then
  fail_test "Expected a non-zero exit on an unknown dependsOnRuns reference" "$OUTPUT_FILE"
fi
if [[ -s "$FAKE_RALPH_EVENTS_FILE" ]]; then
  fail_test "Runs were launched despite the unknown reference" "$OUTPUT_FILE"
fi
grep -q "run-a' depends on 'ghost'" "$OUTPUT_FILE" \
  || fail_test "Expected the error to name both the run and the bad reference" "$OUTPUT_FILE"

# --- Case 5: dependsOnRuns selects graph mode without --plan or --graph -------

reset_case "auto"
make_run run-a false
make_run run-b false run-a
OUTPUT_FILE="$TEST_ROOT/output-auto"

set +e
"$ORCHESTRATOR" --tool codex --dry-run > "$OUTPUT_FILE" 2>&1 < /dev/null
status=$?
set -e

if [[ "$status" -ne 0 ]]; then
  fail_test "Expected the auto-detected dry run to exit 0, got $status" "$OUTPUT_FILE"
fi
if grep -q "No plan provided" "$OUTPUT_FILE"; then
  fail_test "The orchestrator asked for a plan instead of using the graph" "$OUTPUT_FILE"
fi
grep -q "scheduling as a dependency graph" "$OUTPUT_FILE" \
  || fail_test "Expected the graph mode notice" "$OUTPUT_FILE"
grep -q "Wave 1:  run-a" "$OUTPUT_FILE" \
  || fail_test "Expected run-a in wave 1 of the preview" "$OUTPUT_FILE"
grep -q "Wave 2:  run-b" "$OUTPUT_FILE" \
  || fail_test "Expected run-b in wave 2 of the preview" "$OUTPUT_FILE"
grep -q "event-driven" "$OUTPUT_FILE" \
  || fail_test "Expected the preview to flag that execution is event-driven" "$OUTPUT_FILE"
if [[ -s "$FAKE_RALPH_EVENTS_FILE" ]]; then
  fail_test "A dry run launched something" "$OUTPUT_FILE"
fi

# --- Case 6: an explicit --plan still wins over declared edges ----------------

reset_case "plan-wins"
make_run run-a false
make_run run-b false run-a
OUTPUT_FILE="$TEST_ROOT/output-plan-wins"

set +e
"$ORCHESTRATOR" --tool codex --plan "2" --dry-run > "$OUTPUT_FILE" 2>&1 < /dev/null
status=$?
set -e

if [[ "$status" -ne 0 ]]; then
  fail_test "Expected the stage-mode dry run to exit 0, got $status" "$OUTPUT_FILE"
fi
if grep -q "scheduling as a dependency graph" "$OUTPUT_FILE"; then
  fail_test "An explicit --plan was overridden by graph mode" "$OUTPUT_FILE"
fi
grep -q "Stage 1:  run-b" "$OUTPUT_FILE" \
  || fail_test "Expected the hand-typed plan to be honoured" "$OUTPUT_FILE"

# --- Case 7: a rate limit stops the in-flight runs and the whole graph --------

reset_case "ratelimit"
make_run run-a false
make_run run-b false
OUTPUT_FILE="$TEST_ROOT/output-ratelimit"
echo "75 0" > "$FAKE_RALPH_BEHAVIOR_DIR/run-a"   # rate-limited immediately
echo "0 3" > "$FAKE_RALPH_BEHAVIOR_DIR/run-b"    # unrelated, still in flight

set +e
"$ORCHESTRATOR" --tool codex --graph > "$OUTPUT_FILE" 2>&1 < /dev/null
status=$?
set -e

if [[ "$status" -ne 75 ]]; then
  fail_test "Expected the orchestrator to exit 75 on a rate-limited run, got $status" "$OUTPUT_FILE"
fi

grep -q "run-a: rate-limited (exit 75" "$OUTPUT_FILE" \
  || fail_test "Expected the rate limit to be reported" "$OUTPUT_FILE"

# Outlive run-b's delay before looking: a sibling that was merely orphaned
# instead of terminated would still be sleeping when the orchestrator exits, so
# checking straight away would pass for the wrong reason.
sleep 4

if grep -qx "end run-b" "$FAKE_RALPH_EVENTS_FILE"; then
  fail_test "The in-flight sibling was left running after the rate limit" "$OUTPUT_FILE"
fi

grep -q -- "- run-b (stopped after a rate limit, log: " "$OUTPUT_FILE" \
  || fail_test "Expected the terminated run to be reported in the summary" "$OUTPUT_FILE"

echo "orchestrator graph integration test: ok"
