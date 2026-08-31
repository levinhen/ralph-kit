#!/bin/bash
# The orchestrator only schedules what it was told to schedule. `--only` narrows
# the incomplete runs to a subset, the dependency graph is derived inside that
# subset, and a run whose `dependsOnRuns` points outside it is reported by name
# as unrunnable instead of being launched into a startup gate it would fail.

set -e

TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/ralph-orchestrator-selection-test.XXXXXX")
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
chmod +x "$SCRIPTS_DIR"/*.sh

# Same stand-in as the graph test: record start/end events, honour a per-run
# exit code, and mark a successful run's PRD complete.
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
if [[ -f "$FAKE_RALPH_BEHAVIOR_DIR/$run_id" ]]; then
  read -r exit_code < "$FAKE_RALPH_BEHAVIOR_DIR/$run_id"
fi

if [[ "$exit_code" -eq 0 ]]; then
  prd_file="$STUB_SCRIPTS_DIR/../runs/$run_id/prd.json"
  jq '.userStories |= map(.passes = true)' "$prd_file" > "$prd_file.tmp"
  mv "$prd_file.tmp" "$prd_file"
fi

printf 'end %s\n' "$run_id" >> "$FAKE_RALPH_EVENTS_FILE"
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

# --- Case 1: --only narrows the schedule; unselected runs are left alone ------

reset_case "subset"
make_run run-a false
make_run run-b false
make_run run-c false
OUTPUT_FILE="$TEST_ROOT/output-subset"

set +e
"$ORCHESTRATOR" --tool codex --graph --only "1,3" > "$OUTPUT_FILE" 2>&1 < /dev/null
status=$?
set -e

if [[ "$status" -ne 0 ]]; then
  fail_test "Expected the narrowed graph to exit 0, got $status" "$OUTPUT_FILE"
fi
grep -q "Scheduling 2 of 3 incomplete run(s)" "$OUTPUT_FILE" \
  || fail_test "Expected the selection to report what it narrowed to" "$OUTPUT_FILE"
grep -qx "start run-a" "$FAKE_RALPH_EVENTS_FILE" \
  || fail_test "Selected run-a was not started" "$OUTPUT_FILE"
grep -qx "start run-c" "$FAKE_RALPH_EVENTS_FILE" \
  || fail_test "Selected run-c was not started" "$OUTPUT_FILE"
if grep -qx "start run-b" "$FAKE_RALPH_EVENTS_FILE"; then
  fail_test "The unselected run was started anyway" "$OUTPUT_FILE"
fi
awk '/^Out of scope this time/{s=1;next} /^$/{s=0} s' "$OUTPUT_FILE" \
  | grep -q -- "- run-b" \
  || fail_test "Expected run-b to be listed as out of scope" "$OUTPUT_FILE"

# --- Case 2: run ids select as well as numbers, and a range covers a span -----

reset_case "by-id"
make_run run-a false
make_run run-b false
make_run run-c false
OUTPUT_FILE="$TEST_ROOT/output-by-id"

set +e
"$ORCHESTRATOR" --tool codex --graph --only "run-b, 3" > "$OUTPUT_FILE" 2>&1 < /dev/null
status=$?
set -e

if [[ "$status" -ne 0 ]]; then
  fail_test "Expected a run-id selection to exit 0, got $status" "$OUTPUT_FILE"
fi
grep -qx "start run-b" "$FAKE_RALPH_EVENTS_FILE" \
  || fail_test "The run selected by id was not started" "$OUTPUT_FILE"
grep -qx "start run-c" "$FAKE_RALPH_EVENTS_FILE" \
  || fail_test "The run selected by number was not started" "$OUTPUT_FILE"
if grep -qx "start run-a" "$FAKE_RALPH_EVENTS_FILE"; then
  fail_test "An unselected run was started" "$OUTPUT_FILE"
fi

reset_case "range"
make_run run-a false
make_run run-b false
make_run run-c false
OUTPUT_FILE="$TEST_ROOT/output-range"

set +e
"$ORCHESTRATOR" --tool codex --graph --only "2-3" > "$OUTPUT_FILE" 2>&1 < /dev/null
status=$?
set -e

if [[ "$status" -ne 0 ]]; then
  fail_test "Expected a range selection to exit 0, got $status" "$OUTPUT_FILE"
fi
if grep -qx "start run-a" "$FAKE_RALPH_EVENTS_FILE"; then
  fail_test "A range selection reached outside itself" "$OUTPUT_FILE"
fi
grep -qx "start run-b" "$FAKE_RALPH_EVENTS_FILE" \
  || fail_test "The range did not start run-b" "$OUTPUT_FILE"
grep -qx "start run-c" "$FAKE_RALPH_EVENTS_FILE" \
  || fail_test "The range did not start run-c" "$OUTPUT_FILE"

# --- Case 3: a dependency outside the selection takes that run out of it ------
#
# run-b needs run-a, which is real but unselected. It cannot run; run-c, which
# needs run-b, cannot run either. run-d is unrelated and still executes.

reset_case "out-of-scope"
make_run run-a false
make_run run-b false run-a
make_run run-c false run-b
make_run run-d false
OUTPUT_FILE="$TEST_ROOT/output-out-of-scope"

set +e
"$ORCHESTRATOR" --tool codex --graph --only "run-b,run-c,run-d" > "$OUTPUT_FILE" 2>&1 < /dev/null
status=$?
set -e

if [[ "$status" -ne 0 ]]; then
  fail_test "An out-of-scope dependency must not fail the orchestrator, got $status" "$OUTPUT_FILE"
fi

if grep -q "Fix those dependsOnRuns references first" "$OUTPUT_FILE"; then
  fail_test "An unselected dependency was treated as a broken reference" "$OUTPUT_FILE"
fi

grep -q "Cannot run in this selection:" "$OUTPUT_FILE" \
  || fail_test "Expected the unrunnable runs to be announced before execution" "$OUTPUT_FILE"
grep -q "run-b  -  needs run-a, not scheduled in this selection" "$OUTPUT_FILE" \
  || fail_test "Expected run-b to name the dependency it is missing" "$OUTPUT_FILE"
grep -q "run-c  -  needs run-b, which cannot run either" "$OUTPUT_FILE" \
  || fail_test "Expected the reason to travel downstream to run-c" "$OUTPUT_FILE"

grep -q "run-b: NOT RUN (needs run-a" "$OUTPUT_FILE" \
  || fail_test "Expected the skip to be restated during execution" "$OUTPUT_FILE"

for skipped in run-a run-b run-c; do
  if grep -qx "start $skipped" "$FAKE_RALPH_EVENTS_FILE"; then
    fail_test "$skipped was launched despite being unrunnable or unselected" "$OUTPUT_FILE"
  fi
done
grep -qx "start run-d" "$FAKE_RALPH_EVENTS_FILE" \
  || fail_test "The unrelated run did not run" "$OUTPUT_FILE"

summary_start=$(grep -n "Graph summary" "$OUTPUT_FILE" | head -1 | cut -d: -f1)
tail -n "+$summary_start" "$OUTPUT_FILE" > "$TEST_ROOT/summary-out-of-scope"
awk '/^Not runnable in this selection:/{s=1;next} s' "$TEST_ROOT/summary-out-of-scope" \
  | grep -q -- "- run-b (needs run-a" \
  || fail_test "Expected run-b under 'Not runnable in this selection'" "$OUTPUT_FILE"
awk '/^Succeeded:/{s=1;next} /^Failed:/{s=0} s' "$TEST_ROOT/summary-out-of-scope" \
  | grep -q -- "- run-d" \
  || fail_test "Expected run-d under Succeeded" "$OUTPUT_FILE"
grep -q "1 runnable run(s) completed successfully; 2 left unrun" "$OUTPUT_FILE" \
  || fail_test "Expected the closing line to separate run from unrun" "$OUTPUT_FILE"

# --- Case 4: a dependency on a run that does not exist is still fatal ---------

reset_case "ghost-with-selection"
make_run run-a false ghost
make_run run-b false
OUTPUT_FILE="$TEST_ROOT/output-ghost-selection"

set +e
"$ORCHESTRATOR" --tool codex --graph --only "1,2" > "$OUTPUT_FILE" 2>&1 < /dev/null
status=$?
set -e

if [[ "$status" -eq 0 ]]; then
  fail_test "An unknown dependsOnRuns id must still be fatal" "$OUTPUT_FILE"
fi
if [[ -s "$FAKE_RALPH_EVENTS_FILE" ]]; then
  fail_test "Runs were launched despite the unknown reference" "$OUTPUT_FILE"
fi
grep -q "run-a' depends on 'ghost'" "$OUTPUT_FILE" \
  || fail_test "Expected the error to name both the run and the bad reference" "$OUTPUT_FILE"

# --- Case 5: a selection that leaves nothing runnable says so and exits 1 -----

reset_case "nothing-runnable"
make_run run-a false
make_run run-b false run-a
OUTPUT_FILE="$TEST_ROOT/output-nothing-runnable"

set +e
"$ORCHESTRATOR" --tool codex --graph --only "run-b" > "$OUTPUT_FILE" 2>&1 < /dev/null
status=$?
set -e

if [[ "$status" -eq 0 ]]; then
  fail_test "Expected a non-zero exit when the selection can run nothing" "$OUTPUT_FILE"
fi
if [[ -s "$FAKE_RALPH_EVENTS_FILE" ]]; then
  fail_test "Something was launched even though nothing was runnable" "$OUTPUT_FILE"
fi
grep -q "Nothing in this selection can run" "$OUTPUT_FILE" \
  || fail_test "Expected the empty selection to be explained" "$OUTPUT_FILE"

# --- Case 6: a bad selection is refused before anything starts ----------------

reset_case "bad-selection"
make_run run-a false
make_run run-b false
OUTPUT_FILE="$TEST_ROOT/output-bad-selection"

set +e
"$ORCHESTRATOR" --tool codex --graph --only "9" > "$OUTPUT_FILE" 2>&1 < /dev/null
status=$?
set -e

if [[ "$status" -eq 0 ]]; then
  fail_test "An out-of-range selection must not be accepted" "$OUTPUT_FILE"
fi
grep -q "out of range (1-2)" "$OUTPUT_FILE" \
  || fail_test "Expected the range error to state the valid range" "$OUTPUT_FILE"

set +e
"$ORCHESTRATOR" --tool codex --graph --only "run-nope" > "$OUTPUT_FILE" 2>&1 < /dev/null
status=$?
set -e

if [[ "$status" -eq 0 ]]; then
  fail_test "An unknown run id in --only must not be accepted" "$OUTPUT_FILE"
fi
grep -q "'run-nope' is neither a listed run id nor a number" "$OUTPUT_FILE" \
  || fail_test "Expected an unknown selection token to be named" "$OUTPUT_FILE"

if [[ -s "$FAKE_RALPH_EVENTS_FILE" ]]; then
  fail_test "A rejected selection still launched something" "$OUTPUT_FILE"
fi

# --- Case 7: --only narrows a stage plan's numbering too ----------------------

reset_case "stage-selection"
make_run run-a false
make_run run-b false
make_run run-c false
OUTPUT_FILE="$TEST_ROOT/output-stage-selection"

set +e
"$ORCHESTRATOR" --tool codex --only "2,3" --plan "1 > 2" --dry-run > "$OUTPUT_FILE" 2>&1 < /dev/null
status=$?
set -e

if [[ "$status" -ne 0 ]]; then
  fail_test "Expected the narrowed stage dry run to exit 0, got $status" "$OUTPUT_FILE"
fi
grep -q "Stage 1:  run-b" "$OUTPUT_FILE" \
  || fail_test "Plan numbers should address the narrowed list (1 = run-b)" "$OUTPUT_FILE"
grep -q "Stage 2:  run-c" "$OUTPUT_FILE" \
  || fail_test "Plan numbers should address the narrowed list (2 = run-c)" "$OUTPUT_FILE"

# --- Case 8: stage mode warns about a dependency its plan leaves out ----------

reset_case "stage-warning"
make_run run-a false
make_run run-b false run-a
OUTPUT_FILE="$TEST_ROOT/output-stage-warning"

set +e
"$ORCHESTRATOR" --tool codex --plan "2" --dry-run > "$OUTPUT_FILE" 2>&1 < /dev/null
status=$?
set -e

if [[ "$status" -ne 0 ]]; then
  fail_test "The heads-up must not block the plan, got exit $status" "$OUTPUT_FILE"
fi
grep -q "Heads-up: this plan does not schedule everything it depends on:" "$OUTPUT_FILE" \
  || fail_test "Expected a heads-up about the unscheduled dependency" "$OUTPUT_FILE"
grep -q "run-b needs run-a" "$OUTPUT_FILE" \
  || fail_test "Expected the heads-up to name the missing dependency" "$OUTPUT_FILE"

echo "orchestrator selection integration test: ok"
